# MongoDB Full Replace 안티패턴 검증 보고서 (최종본)

> 원문서의 메커니즘·수치·결과 주장이 MongoDB 공식 동작과 일치하는지 1차 자료로 대조하고,
> 핵심 수치인 "세컨더리 랙 45초"를 재현 가능한 형태로 검증할 수 있는 실험을 설계.
> 보충 검증 P1~P5 패치 모두 적용한 최종본.

---

## 한 줄 결론

**메커니즘은 공식 문서·소스 코드로 모두 확정, 정량 수치는 환경 의존적이라 직접 재현이 필요함.** 특히 45초 랙은 "트랜잭션의 chained applyOps + 배열 인라인 diff + timestamp hole"이라는 다중 메커니즘에서 충분히 발생 가능한 값이지만, 정확한 재현은 워크로드·하드웨어·MongoDB 메이저 버전에 따라 다르다.

| 영역 | 검증 강도 |
|---|---|
| 메커니즘 (왜 그런 일이 일어나는가) | ★★★★★ 공식 문서·소스 코드로 확정 |
| 정량 수치 (구체적 값) | ★★☆☆☆ plausible하지만 환경 종속 |
| 결과 비교 (개선 폭) | ★★★☆☆ 방향성은 맞고 폭은 워크로드 의존 |

---

## 1. 공식 문서 대조 — 메커니즘 검증

원문서의 핵심 주장 7가지를 MongoDB 공식 자료와 매핑.

| # | 원문 주장 | 공식 근거 | 강도 |
|---|---|---|---|
| **M1** | dirty bytes가 eviction trigger 20%를 돌파하면 application thread가 강제 동원됨 | WiredTiger 공식: `eviction_dirty_trigger` 기본 20%. *"Application threads will be throttled if the percentage of dirty data reaches the eviction_dirty_trigger"* (`eviction_dirty_target` 기본 5%) | ★★★★★ |
| **M2** | write ticket이 0이 되면 큐가 폭증 | WiredTiger 공식: 최대 128 read/write tickets. 고갈 시 큐 적재. MongoDB 7.0+는 동적 조정(상한 128 유지). `db.serverStatus().queues.execution`으로 모니터링. | ★★★★★ |
| **M3** | `$v:2` diff 포맷 — 부분 변경만 oplog에 기록 | `$set` 공식 문서: *"Efficient Oplog Entries: $set optimizes replication by writing only the updated fields to the oplog instead of the entire document"*. ※ `$v:2`라는 포맷명 자체는 내부 구현이라 공개 문서엔 없음. 동작은 확인됨. | ★★★☆☆ |
| **M4** | 큰 배열 통째 교체 → diff에 배열 전체 인라인됨 | M3에서 파생. Full Replace 시 도큐먼트 전체가 oplog에 기록되므로 큰 배열도 그대로 포함. 공개 문서에 직접 기술 없음. | ★★★☆☆ |
| **M5** | 트랜잭션 commit 시 16MB 초과 → chained applyOps 분할 | **두 개의 1차 자료 동시 확인.** 공식: *"MongoDB creates as many oplog entries as necessary... each oplog entry still must be within the BSON document size limit of 16MB"*. 소스 README: *"transactions larger than this require multiple applyOps oplog entries upon committing"* | ★★★★★ |
| **M6** | 세컨더리는 chained entry를 전부 받아야 적용 시작 → 랙 발생 | 소스 README 직접 인용: *"A secondary must wait until it receives the final applyOps oplog entry of a large unprepared transaction... before applying entries"* + *"it will traverse the oplog chain to get all the operations from the transaction"* | ★★★★★ |
| **M7** | replWriterThreadCount로 세컨더리 병렬 복제, 동일 `_id`는 직렬 | 소스 README + Data Synchronization 공식: *"MongoDB groups batches by document ID (WiredTiger) and simultaneously applies each group of operations using a different thread. MongoDB always applies write operations to a given document in their original write order"* | ★★★★★ |

**판정**: 메커니즘 7개 모두 1차 자료로 뒷받침. M3·M4는 동작은 확인되나 `$v:2` 포맷명은 내부 구현 상세로 외부 공유 문서에는 부적합.

---

## 2. 원문서에 없던 추가 발견

### 2-1. Secondary의 실제 동작 — "완전 블로킹"이 아니라 "stale data + 동일 `_id` 직렬화"

원문서에서 "세컨더리 랙 45초"를 "세컨더리가 멈췄다"로 해석할 여지가 있으나, 공식 문서 동작은 그것보다 정밀하다.

**Replica Set Data Synchronization 공식 문서**:

> "MongoDB applies write operations in batches using multiple threads to improve concurrency. MongoDB groups batches by document ID (WiredTiger) and simultaneously applies each group of operations using a different thread."

> "Read operations that target secondaries and are configured with a read concern level of 'local' or 'majority' read from a WiredTiger snapshot of the data if the read takes place on a secondary where replication batches are being applied."

> "Reading from a snapshot guarantees a consistent view of the data, and allows the read to occur simultaneously with the ongoing replication without the need for a lock."

따라서 45초 랙의 실제 영향은 다음 둘로 분해된다:

- **쓰기**: chained applyOps 완료 전까지 **동일 `_id`에 대한 write만 직렬 대기** (다른 `_id`는 병렬 적용 가능)
- **읽기**: `local`·`majority` read concern은 WiredTiger snapshot에서 즉시 처리되나, apply가 완료되기 전 시점이면 **stale data 반환**

→ "읽기가 멈춘다"가 아니라 "45초 동안 stale data를 보여준다 + 동일 `_id` write 직렬화"가 정확한 묘사.

※ 참고: 별도 트리거 경로인 `applyOps` **명령어**는 공식 문서에 *"obtains a global write lock"*이라고 적혀 있으나, 이는 **사용자가 직접 호출하는 internal command**(mongorestore --oplogReplay 등)에 대한 기술이며, secondary의 일반 oplog 적용 경로와는 다른 코드 경로. 두 가지를 혼동하면 안 됨.

### 2-2. Timestamp hole — 랙의 두 번째 독립 경로

MongoDB Troubleshoot Replica Sets 공식 문서:

> "If writeB commits first at Timestamp2, replication pauses until writeA commits, since writeA's oplog entry (Timestamp1) is required before replication can copy oplog entries to secondaries."

큰 트랜잭션이 이른 타임스탬프를 점유한 채 늦게 commit하면, 이후에 들어온 더 작은 op들도 replication이 멈춘다. 45초 랙이 단일 원인이 아니라 두 경로(chained applyOps + timestamp hole)의 합일 수 있음.

측정 지표: slow query 로그의 `totalOplogSlotDurationMicros`.

### 2-3. Slow oplog 적용 로그 — 실험·운영 직접 활용 가능

공식 문서 (Replica Set Oplog v7.0/v8.0 공통):

> "Secondary members of a replica set log oplog entries that take longer than the slow operation threshold to apply. These messages are logged for the secondaries under the REPL component with the text `applied op: <oplog entry> took <num>ms`. Not affected by the logLevel/systemLog.verbosity level. Not captured by the profiler and not affected by the profiling level. Affected by `slowOpSampleRate`."

→ 프로파일링 레벨·로그 레벨 조정 없이 항상 확보 가능. 추가 운영 비용 없음.

---

## 3. 정량 수치 — Plausibility 평가

### 3-1. Plausible (메커니즘으로 설명되는 수치)

| 수치 | 평가 |
|---|---|
| Write 단량 100KB → 3KB | $set 전환 시 변경 필드 size에 비례하므로 long-tail 도큐먼트에서 30배 차이는 자연스러움. ★★★★☆ |
| 세컨더리 랙 45초 → 2초 이하 | chained applyOps 제거 + timestamp hole 해소 시 한 자릿수 초로 떨어지는 패턴은 합리적. §2 신규 발견으로 plausibility 상향. ★★★★☆ |
| dirty bytes 5% target / 20% trigger | WiredTiger 공식 기본값과 정확히 일치. ★★★★★ |
| Oplog 윈도우 72시간 회복 | write payload가 줄면 같은 oplog size로 윈도우가 비례 확장. ★★★★☆ |

### 3-2. 단위·정의 보강 권고

| 수치 | 의심 사유 및 권고 |
|---|---|
| **"dirty bytes 생성 속도 1/2 감축"** | write size가 ~33× 줄었는데 dirty bytes가 절반만 줄었다면 op rate가 그만큼 늘었다는 의미 — 동일 트래픽 가정에서 측정한 건지 명시 필요. |
| **"Oplog 크기 1/175 감소"** | 매우 구체적인 숫자. 측정 구간(피크/평균/누적)과 산식 명시 권고. |
| **IOWAIT 874%** | 멀티코어 합산 표기일 가능성 높음. "12-core 기준 sum-of-CPU %" 등 단위 명시 필요. |
| **90K ops/sec, Write I/O 1.3 GB/s** | 인스턴스 사양·디스크 종류 없이 정상/비정상 판단 불가. |
| **"Oplog 윈도우 40분 → 72시간"** | 4.0+ MongoDB에서 oplog는 capped 한계를 초과해 성장 가능. *"Unlike other capped collections, the oplog can grow past its configured size limit to avoid deleting the majority commit point."* 윈도우(시간)가 줄어도 디스크 사용량은 계속 늘었을 수 있음. 측정 지표 둘 다 기록 권고: `rs.printReplicationInfo()` → `timeDiffHours` (윈도우), `db.oplog.rs.stats().size` (디스크). |
| **"Oplog 윈도우 회복 후 디스크 반환"** | `replSetResizeOplog` 공식 문서: *"If the oplog grows beyond its maximum size, the `mongod` may continue to hold that disk space even if the oplog returns to its maximum size or is configured for a smaller maximum size."* + *"Reducing the oplog size does not immediately reclaim that disk space."* → **oplog 윈도우가 회복되더라도 디스크 공간은 자동 반환되지 않는다.** 회수하려면 `compact` 명령을 `local.oplog.rs`에 직접 실행해야 함. 원문서에서 "회복"이 "디스크 반환"을 의미했다면 정정 필요. |

---

## 4. 45초 랙 재현 실험 설계

### 4-1. 가설

> 동일한 도큐먼트 집합·동일한 트랜잭션 크기에서, **Full Replace** 방식은 **$set 부분 업데이트** 방식보다 세컨더리 랙을 한 자릿수 이상 크게 발생시킨다.
>
> 메커니즘: 큰 배열을 통째로 교체할 때 oplog diff에 배열이 그대로 인라인 → chained applyOps 다수 발생 → 세컨더리가 전체 chain 수신 전 적용 불가 + 동일 `_id` write 직렬화.
>
> **반증 조건**: 두 시나리오의 랙 차이가 2배 미만이면 가설 실패.

### 4-2. 환경 셋업

3-node replica set, Docker Compose. **버전 고정 필수** (§4-9 참조).

```yaml
# experiment/docker-compose.yml
version: '3.8'
services:
  mongo1:
    image: mongo:7.0   # 또는 mongo:8.0 — 택일, 혼합 금지
    command: ["--replSet", "rs0", "--bind_ip_all", "--oplogSize", "1024"]
    ports: ["27017:27017"]
  mongo2:
    image: mongo:7.0
    command: ["--replSet", "rs0", "--bind_ip_all", "--oplogSize", "1024"]
    ports: ["27018:27017"]
  mongo3:
    image: mongo:7.0
    command: ["--replSet", "rs0", "--bind_ip_all", "--oplogSize", "1024"]
    ports: ["27019:27017"]
```

```bash
docker-compose up -d && sleep 10
docker exec mongo1 mongosh --quiet --eval '
rs.initiate({
  _id: "rs0",
  members: [
    {_id: 0, host: "mongo1:27017", priority: 2},
    {_id: 1, host: "mongo2:27017"},
    {_id: 2, host: "mongo3:27017"}
  ]
})'
```

### 4-3. 데이터 준비 — Long-tail 분포 시뮬레이션

p99 278KB long-tail 분포 모사: 1000개 도큐먼트, 5%가 큰 배열(2000 entry × ~100B = ~200KB).

```javascript
// experiment/seed.js
db = db.getSiblingDB('test');
db.users.drop();
const docs = [];
for (let i = 0; i < 1000; i++) {
  const isLongTail = i % 20 === 0;
  const historyLen = isLongTail ? 2000 : 50;
  docs.push({
    _id: i,
    name: `user${i}`,
    profile: { age: 30, city: 'X' },
    history: Array.from({length: historyLen}, () => ({
      ts: new Date(), action: 'click', meta: 'x'.repeat(50)
    }))
  });
}
db.users.insertMany(docs);
```

### 4-4. 시나리오 — 변수 하나만 다른 비교

같은 `_id` 집합에 같은 의미의 변경을 가한다. 트랜잭션 크기도 동일.

**시나리오 A — Full Replace (안티패턴)**

```javascript
const session = db.getMongo().startSession();
session.startTransaction({writeConcern: {w: "majority"}});
const coll = session.getDatabase('test').users;
for (const id of [0, 20, 40, 60, 80]) {
  const doc = coll.findOne({_id: id});
  doc.history[doc.history.length - 1].action = 'updated';
  coll.replaceOne({_id: id}, doc);  // 도큐먼트 전체 교체
}
session.commitTransaction();
```

**시나리오 B — $set 부분 업데이트 (개선안)**

```javascript
const session = db.getMongo().startSession();
session.startTransaction({writeConcern: {w: "majority"}});
const coll = session.getDatabase('test').users;
for (const id of [0, 20, 40, 60, 80]) {
  const doc = coll.findOne({_id: id}, {projection: {history: 1}});
  const lastIdx = doc.history.length - 1;
  coll.updateOne({_id: id}, {$set: {[`history.${lastIdx}.action`]: 'updated'}});
}
session.commitTransaction();
```

> ⚠️ **버전 주의 (§4-9)**: MongoDB 8.0+에서는 `w:majority`가 "applied"가 아니라 "oplog entry written"으로 의미가 바뀌었다. 7.0과 8.0의 commit 반환 시점이 다르므로 두 버전을 섞어 A/B 비교하면 안 된다. docker image 버전을 반드시 고정.

### 4-5. 측정 지표

| 위계 | 지표 | 출처 | 가설이 맞다면 |
|---|---|---|---|
| **필수** | `replicationLag (sec)` | `rs.status()` 1초 폴링 | A가 B보다 ≥10× |
| **필수** | applyOps chained entry 개수 | `db.oplog.rs.find({"o.applyOps":{$exists:true}})` | A는 다수, B는 1~2개 |
| **필수** | oplog entry 최대 크기 | `$bsonSize` aggregate | A max ≈ 16MB, B는 KB 수준 |
| **필수** | `transactions.totalAborted` | `db.serverStatus().transactions` before/after | 증가 시 §5-2 시나리오 B·C 확인 |
| 보조 | `totalOplogSlotDurationMicros` | slow query 로그 (REPL) | A에서 크게 증가 |
| 보조 | secondary REPL 로그 | `applied op: ... took Nms` | A에서 고값 |
| 보조 | WiredTiger dirty bytes % | `db.serverStatus().wiredTiger.cache` | A가 더 빨리 20% 도달 |
| 보조 | flow control 발동 | `db.serverStatus().flowControl.isLagged` | A에서 `true` |

### 4-6. 실험 실행 흐름

```bash
# 랙 폴링 시작 (별도 터미널)
bash experiment/lag-watch.sh > lag-A.log &

# 시나리오 A 10회 반복
for i in {1..10}; do
  docker exec mongo1 mongosh test < experiment/scenario-A-replace.js
  sleep 2
done
kill %1

# oplog 분석
docker exec mongo1 mongosh --quiet local --eval '
db.oplog.rs.aggregate([
  {$match: {"o.applyOps": {$exists: true}}},
  {$sort: {ts: -1}},
  {$limit: 20},
  {$project: {ts:1, entryCount:{$size:"$o.applyOps"}, bsonSize:{$bsonSize:"$$ROOT"}}}
]).toArray()'

# 시나리오 B 동일 반복 → lag-B.log
```

### 4-7. 부하 사다리 (임계 돌파 재현)

| 단계 | tx 안 도큐먼트 수 | 예상 |
|---|---|---|
| 1 | 1 | 차이 없음 |
| 2 | 5 | A 약간 느림 |
| 3 | 20 | A 명확히 큰 oplog |
| 4 | 50 | chained applyOps 다수 |
| 5 | 100 | A 랙 폭증, B 안정 |

### 4-8. 결과 해석

| 결과 패턴 | 판정 |
|---|---|
| A lag p99 ≥ B의 10×, A applyOps entry ≥ 3개 chained | 가설 통과 ★★★★☆ |
| A·B 차이 2~5× | 가설 일부 통과 — 메커니즘 맞으나 폭은 환경 종속 ★★★☆☆ |
| A·B 차이 거의 없음 | 도큐먼트·트랜잭션 크기 부족. 배열·tx 도큐먼트 수 늘려 재시도 |
| chained applyOps 안 보임 | 트랜잭션 합계가 16MB 미만. 더 큰 배열 또는 더 많은 도큐먼트로 재시도 |

### 4-9. 버전 분기 — MongoDB 8.0 replication 아키텍처 변경

MongoDB 8.0 Release Notes 공식:

> "Starting in MongoDB 8.0, secondaries write and apply oplog entries for each batch in parallel. A writer thread reads new entries from the primary and writes them to the local oplog. An applier thread asynchronously applies these changes to the local database. This change increases replication throughput for secondaries."

8.0 Compatibility Changes:

> "This introduces a breaking change for the `metrics.repl.buffer` status metric, as it now provides information on two buffers instead of one."

측정 지표 버전 분기:

| 지표 | 7.0 이하 | 8.0+ |
|---|---|---|
| `metrics.repl.buffer.count` | ✓ | deprecated |
| `metrics.repl.buffer.maxSizeBytes` | ✓ | deprecated |
| `metrics.repl.buffer.sizeBytes` | ✓ | deprecated |
| `metrics.repl.buffer.write.{count, maxSizeBytes, sizeBytes}` | ❌ | ✓ primary→secondary 수신 단계 |
| `metrics.repl.buffer.apply.{count, maxCount, maxSizeBytes, sizeBytes}` | ❌ | ✓ secondary 적용 단계 (chained applyOps 병목은 여기) |

8.0에서 실험 시 핵심 지표는 **`metrics.repl.buffer.apply.sizeBytes`**. write buffer가 안정적인데 apply buffer가 쌓이면 secondary applier 단계가 병목.

추가로 8.0에서는 multi-document transaction의 insert가 단일 applyOps entry로 batched될 수 있어 **chained applyOps 메커니즘 자체가 약화될 수 있음**. 8.0 실험에서 차이가 안 보이면 검증 실패가 아니라 환경 변화로 해석.

---

## 5. 검증 한계와 추가 확인 필요사항

### 5-1. 원문서 incident MongoDB 버전 미상

§4-9에 따라 6.0/7.0/8.0 중 어느 버전인지에 따라 측정 지표와 실험 비교 가능성이 달라진다. 원문서에 명시 권고.

### 5-2. `transactionLifetimeLimitSeconds` 기본 60초의 영향

MongoDB Production Considerations 공식:

> "By default, a transaction must have a runtime of less than one minute. Transactions that exceed this limit are considered expired and will be aborted by a periodic cleanup process."

> "If you have an uncommitted transaction that causes excessive pressure on the WiredTiger cache, the transaction aborts and returns a write conflict error."

> "If a transaction is too large to ever fit in the WiredTiger cache, the transaction aborts and returns a `TransactionTooLargeForCache` error."

"45초 랙"의 실제 원인을 세 가지 경로로 분리해 확정해야 함:

| 시나리오 | 원인 | 로그 키워드 | "랙"의 의미 |
|---|---|---|---|
| **A** | 트랜잭션 정상 commit + secondary chained replay | 없음 | 실제 replication 지연 (원문서 기술) |
| **B** | 60초 초과 abort → 클라이언트 재시도 누적 | `"abortTransaction"` 60초 전후 타임스탬프 | abort+재시도 누적, replication은 정상 |
| **C** | WiredTiger cache 초과 abort | `"TransactionTooLargeForCache"` | replication 도달 자체가 안 됨 |

원문서 incident 로그에서 위 키워드 검색. B·C 키워드가 없으면 시나리오 A(원문서 기술이 맞음)가 확정.

§4-5 **필수 지표** 추가: `db.serverStatus().transactions.totalAborted` before/after — 증가 시 시나리오 B·C 확인.

### 5-3. Secondary read 동작

§2-1 참조.

### 5-4. Oplog capped 초과 성장 및 디스크 미반환

§3-2 참조. 요점:
- 4.0+에서 oplog는 majority commit point 보호를 위해 설정값을 초과해 성장 가능
- 초과 성장 후 **디스크 공간이 자동 반환되지 않음** (`compact` 명령 필요)
- "Oplog 윈도우 회복 = 디스크 반환"이 아님 — 측정 지표를 윈도우와 디스크 사용량 둘 다 기록해야

---

## 6. 원문서 보강 권고 요약

| 항목 | 조치 |
|---|---|
| M1 eviction dirty 설명 | "5% target / 20% trigger 쌍"으로 명시 |
| M2 write ticket | MongoDB 7.0+ 동적 조정 각주 추가 |
| M3 `$v:2` 명칭 | 공개 문서 미확인 — "변경 필드만 oplog에 기록"으로 대체 권고 |
| M5 chained oplog 근거 | 공식 원문 직접 인용 가능 (production-consideration + repl/README) |
| **신규 — secondary 동작 정확화** | "완전 블로킹" → "stale data + 동일 `_id` write 직렬화" (§2-1) |
| **신규 — timestamp hole** | `totalOplogSlotDurationMicros` — 랙의 두 번째 독립 경로 (§2-2) |
| **신규 — slow oplog REPL 로그** | `applied op: ... took Nms` (§2-3) |
| **신규 — transactionLifetimeLimitSeconds** | 시나리오 A/B/C 구분, 로그 키워드 확인 (§5-2) |
| **신규 — Oplog capped 초과 성장** | 4.0+에서 설정값은 최솟값. 윈도우 회복 ≠ 디스크 반환. `compact` 필요 (§3-2, §5-4) |
| **신규 — MongoDB 8.0 `w:majority` 의미 변경** | 7.0: applied 시점 / 8.0+: written 시점. 버전 고정 필수 (§4-4, §4-9) |
| 단위 명시 | IOWAIT 합산 기준, Write I/O 출처, Oplog 크기 측정 구간 |

---

## 7. 참고 — 1차 자료

| 자료 | URL | 확인 클레임 |
|---|---|---|
| WiredTiger Cache & Eviction Tuning | https://source.wiredtiger.com/mongodb-6.0/tune_cache.html | M1 (dirty trigger 20%, target 5%) |
| MongoDB WiredTiger Storage Engine | https://www.mongodb.com/docs/manual/core/wiredtiger/ | M2 (write tickets max 128, 7.0+ dynamic) |
| MongoDB `$set` Operator | https://www.mongodb.com/docs/manual/reference/operator/update/set/ | M3 (updated fields only in oplog) |
| Transactions Production Considerations | https://www.mongodb.com/docs/manual/core/transactions-production-consideration/ | M5 (chained applyOps, 16MB limit), §5-2 (transactionLifetimeLimitSeconds, TransactionTooLargeForCache) |
| MongoDB Replication Source README | https://github.com/mongodb/mongo/blob/master/src/mongo/db/repl/README.md | M5 M6 M7 (직접 인용) |
| Troubleshoot Replica Sets | https://www.mongodb.com/docs/manual/tutorial/troubleshoot-replica-sets/ | flow control, timestamp hole, slow oplog 로그 |
| applyOps Command | https://www.mongodb.com/docs/manual/reference/command/applyops/ | §2-1 (applyOps 명령어 global write lock — secondary 적용 경로와 구분) |
| Replica Set Oplog | https://www.mongodb.com/docs/manual/core/replica-set-oplog/ | oplog sizing, 4.0+ capped 초과 성장 |
| replSetResizeOplog | https://www.mongodb.com/docs/manual/reference/command/replsetresizeoplog/ | §3-2, §5-4 (oplog 초과 성장 후 디스크 자동 미반환, compact 필요) |
| Replica Set Data Synchronization | https://www.mongodb.com/docs/manual/core/replica-set-sync/ | §2-1 (WiredTiger snapshot read, 병렬 batch apply) |
| FAQ: Concurrency | https://www.mongodb.com/docs/manual/faq/concurrency/ | §2-1 (snapshot read 동시성) |
| MongoDB Limits and Thresholds | https://www.mongodb.com/docs/manual/reference/limits/ | §5-2 (transactionLifetimeLimitSeconds 60s 기본값) |
| MongoDB 8.0 Release Notes | https://www.mongodb.com/docs/manual/release-notes/8.0/ | §4-9 (writer/applier 분리, 신규 metrics) |
| MongoDB 8.0 Compatibility Changes | https://www.mongodb.com/docs/manual/release-notes/8.0-compatibility/ | §4-9, §4-4 (`w:majority` 의미 변경) |
