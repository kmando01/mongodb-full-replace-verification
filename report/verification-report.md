# MongoDB Full Replace 안티패턴 주장 검증 보고서

> 원문서의 메커니즘·수치·결과 주장이 MongoDB 공식 동작과 일치하는지 1차 자료로 대조하고,
> 핵심 수치인 "세컨더리 랙 45초"를 재현 가능한 형태로 검증할 수 있는 실험을 설계한다.

---

## 한 줄 결론

**메커니즘은 공식 문서·소스 코드로 모두 확정, 정량 수치는 환경 의존적이라 직접 재현이 필요함.**
특히 45초 랙은 "트랜잭션의 chained applyOps + 배열 인라인 diff + global write lock + timestamp hole"이라는
4중 메커니즘에서 충분히 발생 가능한 값이지만, 정확한 재현은 워크로드·하드웨어·MongoDB 버전에 따라 다르다.

| 영역 | 검증 강도 |
|---|---|
| 메커니즘 (왜 그런 일이 일어나는가) | ★★★★★ 공식 문서·소스 코드로 확정 |
| 정량 수치 (구체적 값) | ★★☆☆☆ plausible하지만 환경 종속 |
| 결과 비교 (개선 폭) | ★★★☆☆ 방향성은 맞고 폭은 워크로드 의존 |

---

## 1. 공식 문서 대조 — 메커니즘 검증

원문서의 핵심 주장 7가지를 MongoDB 공식 자료와 매핑한다.

| # | 원문 주장 | 공식 근거 | 강도 |
|---|---|---|---|
| **M1** | dirty bytes가 eviction trigger 20%를 돌파하면 application thread가 강제 동원됨 | WiredTiger 공식: `eviction_dirty_trigger` 기본 20%. **"Application threads will be throttled if the percentage of dirty data reaches the `eviction_dirty_trigger`."** (`eviction_dirty_target` 기본 5%) | ★★★★★ |
| **M2** | write ticket이 0이 되면 큐가 폭증 | WiredTiger 공식: 최대 128 read/write tickets. 고갈 시 큐 적재. MongoDB 7.0+는 동적 조정(상한 128 유지). `db.serverStatus().queues.execution`으로 모니터링. | ★★★★★ |
| **M3** | `$v:2` diff 포맷 — 부분 변경만 oplog에 기록 | `$set` 공식 문서: **"Efficient Oplog Entries: `$set` optimizes replication by writing only the updated fields to the oplog instead of the entire document."** ※ `$v:2`라는 포맷명 자체는 내부 구현이라 공개 문서에 없음. 동작은 확인됨. | ★★★☆☆ |
| **M4** | 큰 배열 통째 교체 → diff에 배열 전체 인라인됨 | M3에서 파생. Full Replace 시 도큐먼트 전체가 oplog에 기록되므로 큰 배열도 그대로 포함. 단, 공개 문서에 직접 기술 없음. | ★★★☆☆ |
| **M5** | 트랜잭션 commit 시 16MB 초과 → chained applyOps 분할 | **두 개의 1차 자료 동시 확인.** 공식 문서: *"MongoDB creates as many oplog entries as necessary... each oplog entry still must be within the BSON document size limit of 16MB."* 소스 README: *"transactions larger than this require multiple `applyOps` oplog entries upon committing."* | ★★★★★ |
| **M6** | 세컨더리는 chained entry를 전부 받아야 적용 시작 → 랙 발생 | 소스 README 직접 인용: **"A secondary must wait until it receives the final `applyOps` oplog entry of a large unprepared transaction... before applying entries."** + **"it will traverse the oplog chain to get all the operations from the transaction."** | ★★★★★ |
| **M7** | replWriterThreadCount로 세컨더리 병렬 복제, 동일 `_id`는 직렬 | 소스 README: **"Operations on the same collection can still be parallelized if they are working with distinct documents."** 동일 `_id` 집중 시 병렬도 저하 확인. | ★★★★★ |

**판정**: 메커니즘 7개 모두 1차 자료로 뒷받침된다. M3·M4는 동작이 확인되나 `$v:2` 포맷명은 내부 구현 상세로 외부 공유 문서에는 부적합.

---

## 2. 원문서에 없던 추가 발견 (검증 중 신규 확인)

### 2-1. `applyOps` → 세컨더리에서 global write lock 획득

MongoDB `applyOps` 공식 문서:

> **"Obtains a global write lock — blocks other operations until completion."**

원문서는 "랙 발생"으로만 기술했지만, 세컨더리가 큰 트랜잭션의 applyOps를 적용하는 동안
**해당 세컨더리의 모든 읽기/쓰기가 완전히 블로킹**된다.
45초 랙이 단순 "느림"이 아니라 "멈춤"인 이유가 여기서 추가로 설명된다.

### 2-2. timestamp hole → 세컨더리 랙의 두 번째 경로

MongoDB troubleshoot 공식 문서:

> "If writeB commits first at Timestamp2, replication **pauses until writeA commits**,
> since writeA's oplog entry (Timestamp1) is required before replication can copy oplog entries to secondaries."

큰 트랜잭션이 이른 타임스탬프를 점유한 채 늦게 commit하면,
이후에 들어온 더 작은 op들도 replication이 멈춘다. 45초 랙의 cascading 효과를 설명하는 독립 경로.
측정 지표: slow query 로그의 `totalOplogSlotDurationMicros`.

### 2-3. slow oplog entry 로그 — 실험 시 바로 활용 가능

공식 문서:

> "Secondary members log oplog entries that take longer than the slow operation threshold to apply."
> Log format: `applied op: <oplog entry> took <num>ms` (REPL component)

프로파일링 레벨·로그 레벨과 무관하게 항상 기록된다. 실험 §4.5 측정 지표에 추가.

---

## 3. 정량 수치 — Plausibility 평가

### 3-1. Plausible (메커니즘으로 설명되는 수치)

| 수치 | 평가 |
|---|---|
| Write 단량 100KB → 3KB | $set 전환 시 변경 필드 size에 비례하므로 long-tail 도큐먼트에서 30배 차이는 자연스러움. ★★★★☆ |
| 세컨더리 랙 45초 → 2초 이하 | chained applyOps 제거 + global write lock 해소 시 한 자릿수 초로 떨어지는 패턴은 합리적. **§2 신규 발견으로 plausibility 상향.** ★★★★☆ |
| dirty bytes 5% target / 20% trigger | WiredTiger 공식 기본값과 정확히 일치. ★★★★★ |
| Oplog 윈도우 72시간 회복 | write payload가 줄면 같은 oplog size로 윈도우가 비례 확장. ★★★★☆ |

### 3-2. 단위·정의 보강 권고

| 수치 | 의심 사유 및 권고 |
|---|---|
| **"dirty bytes 생성 속도 1/2 감축"** | write size가 ~33× 줄었는데 dirty bytes가 절반만 줄었다면 op rate가 그만큼 늘었다는 의미 — 동일 트래픽에서 측정한 건지 명시 필요. |
| **"Oplog 크기 1/175 감소"** | 매우 구체적인 숫자. 측정 구간(피크/평균/누적)과 산식 명시 권고. |
| **IOWAIT 874%** | 멀티코어 합산 표기일 가능성 높음. "12-core 기준 sum-of-CPU %" 등으로 단위 명시 필요. |
| **90K ops/sec, Write I/O 1.3 GB/s** | 인스턴스 사양·디스크 종류 없이 정상/비정상 판단 불가. |

---

## 4. 45초 랙 재현 실험 설계

### 4-1. 가설

> 동일한 도큐먼트 집합·동일한 트랜잭션 크기에서,
> **Full Replace** 방식은 **$set 부분 업데이트** 방식보다 세컨더리 랙을 한 자릿수 이상 크게 발생시킨다.
>
> 메커니즘: 큰 배열을 통째로 교체할 때 oplog diff에 배열이 그대로 인라인 → chained applyOps 다수 발생
> → 세컨더리가 전체 chain 수신 전 적용 불가 + global write lock으로 완전 블로킹.
>
> 반증 조건: 두 시나리오의 랙 차이가 2배 미만이면 가설 실패.

### 4-2. 환경 셋업

`experiment/docker-compose.yml` 참고 — 3-node replica set, oplogSize 1024MB.

```bash
docker-compose -f experiment/docker-compose.yml up -d
sleep 10
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

`experiment/seed.js` 참고.

### 4-4. 시나리오 — 변수 하나만 다른 비교

같은 `_id` 집합에 같은 의미의 변경을 가한다. 트랜잭션 크기도 동일.

**시나리오 A — Full Replace (안티패턴)** → `experiment/scenario-A-replace.js`

```javascript
const session = db.getMongo().startSession();
session.startTransaction();
const coll = session.getDatabase('test').users;
for (const id of [0, 20, 40, 60, 80]) {  // long-tail 5개
  const doc = coll.findOne({_id: id});
  doc.history[doc.history.length - 1].action = 'updated';
  coll.replaceOne({_id: id}, doc);  // 도큐먼트 전체 교체
}
session.commitTransaction();
```

**시나리오 B — $set 부분 업데이트 (개선안)** → `experiment/scenario-B-set.js`

```javascript
const session = db.getMongo().startSession();
session.startTransaction();
const coll = session.getDatabase('test').users;
for (const id of [0, 20, 40, 60, 80]) {
  const doc = coll.findOne({_id: id}, {projection: {history: 1}});
  const lastIdx = doc.history.length - 1;
  coll.updateOne({_id: id}, {$set: {[`history.${lastIdx}.action`]: 'updated'}});
}
session.commitTransaction();
```

### 4-5. 측정 지표

| 위계 | 지표 | 출처 | 가설이 맞다면 |
|---|---|---|---|
| **필수** | `replicationLag (sec)` | `rs.status()` 1초 폴링 | A가 B보다 ≥10× |
| **필수** | applyOps chained entry 개수 | `db.oplog.rs.find({"o.applyOps":{$exists:true}})` | A는 다수, B는 1~2개 |
| **필수** | oplog entry 최대 크기 | `$bsonSize` aggregate | A max ≈ 16MB, B는 KB 수준 |
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
| A·B 차이 거의 없음 | 도큐먼트·트랜잭션 크기 부족. 배열 크기·tx 도큐먼트 수 늘려 재시도 |
| chained applyOps 안 보임 | 트랜잭션 합계가 16MB 미만. 더 큰 배열 또는 더 많은 도큐먼트로 재시도 |

### 4-9. 버전 주의

- MongoDB 7.0+에서는 generic batch optimization으로 6.0보다 차이 폭이 작을 수 있음
- 트랜잭션 없이 단발 update만 비교하면 chained 메커니즘이 발동하지 않음 — 트랜잭션 필수
- `w: "majority"` write concern 명시해야 commit 시점이 일관되게 측정됨

---

## 5. 원문서 보강 권고 요약

| 항목 | 조치 |
|---|---|
| M1 eviction dirty 설명 | "5% target / 20% trigger 쌍"으로 명시 |
| M2 write ticket | MongoDB 7.0+ 동적 조정 각주 추가 |
| M3 `$v:2` 명칭 | 공개 문서 미확인 — "변경 필드만 oplog에 기록"으로 대체 권고 |
| M5 chained oplog 근거 | 공식 원문 직접 인용 가능 |
| **신규 추가 권고** | `applyOps` global write lock (§2-1) — 원문서에 누락된 핵심 메커니즘 |
| **신규 추가 권고** | timestamp hole / `totalOplogSlotDurationMicros` (§2-2) — 랙의 두 번째 독립 경로 |
| 실험 측정 지표 | secondary REPL 로그 (`applied op: ... took Nms`) 추가 |
| 단위 명시 | IOWAIT 합산 기준, Write I/O 출처, Oplog 크기 측정 구간 |

---

## 6. 참고 — 1차 자료

| 자료 | URL | 확인 클레임 |
|---|---|---|
| WiredTiger Cache & Eviction | https://source.wiredtiger.com/mongodb-6.0/tune_cache.html | M1 (dirty trigger 20%, target 5%) |
| MongoDB WiredTiger Storage Engine | https://www.mongodb.com/docs/manual/core/wiredtiger/ | M2 (write tickets max 128, 7.0+ dynamic) |
| MongoDB $set Operator | https://www.mongodb.com/docs/manual/reference/operator/update/set/ | M3 (updated fields only in oplog) |
| Transactions Production Considerations | https://www.mongodb.com/docs/manual/core/transactions-production-consideration/ | M5 (chained applyOps, 16MB limit) |
| MongoDB Replication Source README | https://raw.githubusercontent.com/mongodb/mongo/master/src/mongo/db/repl/README.md | M5 M6 M7 (직접 인용) |
| Troubleshoot Replica Sets | https://www.mongodb.com/docs/manual/tutorial/troubleshoot-replica-sets/ | flow control, timestamp hole, slow oplog 로그 |
| applyOps Command | https://www.mongodb.com/docs/manual/reference/command/applyOps/ | §2-1 global write lock |
| Replica Set Oplog | https://www.mongodb.com/docs/manual/core/replica-set-oplog/ | oplog sizing, workload types |
