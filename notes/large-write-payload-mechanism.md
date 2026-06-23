# 큰 write payload가 MongoDB 두 레이어를 동시에 무너뜨리는 메커니즘

> 학습 노트 — 공식 문서·소스 README를 1차 자료로 한 두괄식 정리.
> 검증 보고서가 "이 사람의 incident 주장이 맞는지" 대조했다면, 이 노트는 그 검증에서 확보한 MongoDB 내부 동작 자체를 다음 incident에서 다시 꺼내 쓸 수 있는 형태로 압축한다.

---

## 의문

큰 도큐먼트를 통째로 교체하는 write 패턴이 트래픽 임계 돌파 시 WiredTiger 캐시 레이어와 oplog 복제 레이어를 **동시에** 마비시킨다. 두 레이어는 서로 다른 코드 경로인데 왜 같이 무너지는가? 두 레이어를 연결하는 변수는 무엇인가?

## 결론 (두괄식)

**Write 한 번의 payload size**가 두 레이어를 잇는 단일 변수.

- 캐시 측 — 큰 payload는 dirty bytes를 빠르게 채워 eviction trigger(20%)를 돌파, application thread가 eviction에 강제 동원
- 복제 측 — 큰 payload는 oplog entry size를 키워 16MB 한계 초과 시 chained applyOps로 분할, secondary가 final entry까지 적용 불가

→ payload size 자체를 줄이는 게 근본 해결. 인프라 증설(RAM/oplog 디스크)은 trigger 도달 시점만 미룬다.

핵심 회피 패턴: `replaceOne(doc)`·ORM의 `save()` 자동 전체 교체 → `updateOne({$set: {field: v}})` + 배열은 위치 지정 연산자(`arr.$.field`, `arrayFilters`).

---

## 본문 — 공식 문서로 매핑되는 8가지 메커니즘

### 1. WiredTiger eviction은 application thread를 강제 동원한다

WiredTiger 공식 docs (`tune_cache.html`):

> "Application threads will be throttled if the percentage of dirty data reaches the `eviction_dirty_trigger`."

| 파라미터 | 기본값 | 의미 |
|---|---|---|
| `eviction_dirty_target` | 5% | background eviction 시작 |
| `eviction_dirty_trigger` | 20% | application thread가 eviction에 강제 참여 |

application thread가 강제 참여한다는 건 *client request를 처리할 thread가 cache 정리 작업에 차출된다*는 뜻. write ticket(WiredTiger 동시 처리 상한 128) 고갈 → 큐 폭증 → 응답 시간 기하급수 증가.

### 2. `$set`이 oplog에 더 작게 기록되는 이유

`$set` Operator 공식 docs:

> "Efficient Oplog Entries: `$set` optimizes replication by writing only the updated fields to the oplog instead of the entire document."

- `replaceOne(doc)` — 도큐먼트 전체가 oplog entry에 기록
- `updateOne({$set: {field: v}})` — 변경 필드만 diff로 기록

**함정**: 배열을 통째로 교체하는 `$set` (`$set: {arr: [...]}`)은 배열 전체가 diff에 그대로 인라인됨. 위치 지정 연산자(`arr.$.field`)는 sub-document diff로 축약되어 인라인 회피.

### 3. 트랜잭션이 16MB를 넘으면 chained applyOps로 쪼개진다

Production Considerations 공식 docs:

> "MongoDB creates as many oplog entries as necessary... each oplog entry still must be within the BSON document size limit of 16MB."

Replication Source README (`mongo/src/mongo/db/repl/README.md`):

> "transactions larger than this require multiple `applyOps` oplog entries upon committing."

→ 트랜잭션 commit 시점에 oplog entry가 `prevOpTime`으로 연결된 chain 형태로 분할. 각 entry는 ≤16MB지만 chain 전체는 훨씬 클 수 있다.

### 4. 세컨더리는 final entry까지 적용을 시작하지 못한다

repl/README:

> "A secondary must wait until it receives the final `applyOps` oplog entry of a large unprepared transaction... before applying entries. ... it will traverse the oplog chain to get all the operations from the transaction."

→ chain의 첫 entry가 도착해도 마지막까지 다 받기 전엔 적용 안 함. 트랜잭션이 클수록 secondary의 첫 entry 도착~적용 시작 사이 시간이 누적되어 lag로 관측됨.

### 5. Timestamp hole이 후행 op까지 차단한다

Troubleshoot Replica Sets 공식 docs:

> "If writeB commits first at Timestamp2, replication pauses until writeA commits, since writeA's oplog entry (Timestamp1) is required before replication can copy oplog entries to secondaries."

→ 큰 트랜잭션이 이른 timestamp를 점유한 채 늦게 commit하면, 이후 들어온 작은 op도 replication이 멈춤. 측정 지표: slow query 로그의 `totalOplogSlotDurationMicros`.

### 6. Secondary read는 멈추지 않는다 (흔한 오해)

Data Synchronization 공식 docs:

> "Read operations that target secondaries and are configured with a read concern level of 'local' or 'majority' read from a WiredTiger snapshot of the data if the read takes place on a secondary where replication batches are being applied."
>
> "Reading from a snapshot guarantees a consistent view of the data, and allows the read to occur simultaneously with the ongoing replication without the need for a lock. As a result, secondary reads requiring these read concern levels no longer need to wait for replication batches to be applied, and can be handled as they are received."

→ "랙 = 세컨더리 멈춤"이 아니다. 실제 동작은 **stale data 반환** + **동일 `_id`에 대한 write만 직렬 대기**. 다른 `_id`의 write는 `replWriterThreadCount` 기반 thread pool로 병렬 적용된다.

※ 별도 경로인 `applyOps` 명령어(mongorestore --oplogReplay 등)는 공식 문서에 *"obtains a global write lock"*이라 적혀 있으나, 이는 사용자가 직접 호출하는 internal command 경로이며 secondary의 일반 oplog 적용 경로와는 다른 코드 경로다. 둘을 혼동하면 안 됨.

### 7. Oplog는 4.0+부터 capped를 초과 성장한다

Replica Set Oplog 공식 docs:

> "Unlike other capped collections, the oplog can grow past its configured size limit to avoid deleting the majority commit point."

→ 4.0+ MongoDB에서 oplog 설정값은 **최댓값이 아니라 최솟값**으로 동작. secondary가 majority lag을 넘어 떨어지지 않도록 oplog가 보호된다.

`replSetResizeOplog` 공식 docs:

> "If the oplog grows beyond its maximum size, the `mongod` may continue to hold that disk space even if the oplog returns to its maximum size or is configured for a smaller maximum size."
>
> "Reducing the oplog size does not immediately reclaim that disk space."

→ "oplog 윈도우 회복"과 "디스크 반환"은 별개. 디스크 회수는 `compact` 명령을 `local.oplog.rs`에 직접 실행해야 한다.

### 8. MongoDB 8.0의 writer/applier 분리

8.0 Release Notes:

> "Starting in MongoDB 8.0, secondaries write and apply oplog entries for each batch in parallel. A writer thread reads new entries from the primary and writes them to the local oplog. An applier thread asynchronously applies these changes to the local database."

8.0 Compatibility Changes:

> "Starting in MongoDB 8.0, write operations that use the 'majority' write concern return an acknowledgment when the majority of replica set members have written the oplog entry for the change. In previous releases, these operations would wait and return an acknowledgment after the majority of replica set members applied the change."

| | 7.0 이하 | 8.0+ |
|---|---|---|
| 수신·적용 | 단일 thread | writer/applier 분리 |
| 측정 지표 | `metrics.repl.buffer.{count, sizeBytes}` | `metrics.repl.buffer.write.sizeBytes` (수신) / `.apply.sizeBytes` (적용) |
| `w:majority` 반환 시점 | 과반이 **applied** | 과반이 **written (received)** |

→ 8.0에서는 multi-document transaction의 insert가 단일 applyOps entry로 batched될 수 있어 chained 메커니즘 자체가 약화될 수 있음. 6.x/7.x와 8.0+를 섞어 비교하면 안 됨.

---

## 트레이드오프 / 적용 가이드

### 언제 `$set` 부분 업데이트가 무조건 이득인가

- 변경 필드가 도큐먼트 전체의 일부일 때 (대부분의 update 케이스)
- ORM/ODM의 dirty tracking이 자동으로 안 되는 환경에서 명시적 `$set`
- 트랜잭션 내부 update — oplog payload 최소화가 곧 chained applyOps 회피

### 언제 Full Replace가 의도적으로 옳은가

- 도큐먼트 전체가 의미적으로 한 단위로 갈아끼워질 때 (캐시 entry 통째 교체)
- 변경 필드가 너무 많아 `$set` 명시가 더 복잡해질 때
- 마이그레이션·일괄 보정 작업 (maintenance window 필요)

### 배열 갱신 패턴

| 패턴 | 효과 |
|---|---|
| `$set: {arr: <newArr>}` | ❌ 배열 전체 oplog 인라인 — 회피 |
| `arr.$.field` | 단일 매칭 element 갱신 |
| `arr.$[<id>].field` + `arrayFilters` | 조건 매칭 다수 element 갱신 |
| `$push`, `$pull`, `$addToSet` | 배열 추가/제거 |

### 운영 모니터링 지표

| 지표 | 출처 | 임계 |
|---|---|---|
| WiredTiger dirty % | `db.serverStatus().wiredTiger.cache["tracked dirty bytes"] / ["maximum bytes configured"]` | 5% target, 20% trigger |
| Oplog entry max size | `db.oplog.rs.aggregate([{$sample:{size:1000}}, {$project:{sz:{$bsonSize:"$$ROOT"}}}])` | 16MB 근접 시 chained 임박 |
| Secondary lag | `rs.status()` optime gap | SLA 의존 |
| Flow control | `db.serverStatus().flowControl.isLagged` | `true`면 primary가 throttled |
| Slow oplog apply | REPL 컴포넌트 로그: `applied op: ... took Nms` | 프로파일링·logLevel 무관, 항상 기록 |
| (8.0+) Apply buffer | `metrics.repl.buffer.apply.sizeBytes` | write buffer 안정·apply 증가 → applier 병목 |

### Long-tail 도큐먼트의 함정

평균 가중치 알람(예: `avg(write size)`, `avg(secondary lag)`)은 p99 long-tail에 둔감하다. p99/max 기반 알람을 별도로 두지 않으면 임계 도달 자체가 감지되지 않는다.

---

## 자매 메커니즘 — 함께 보면 좋은 동작

- **MVCC와 long-running transaction**: WiredTiger는 MVCC라 long-running transaction이 있으면 cache에서 오래된 버전을 못 비움 — dirty bytes 증가와 별개의 cache pressure 경로
- **TransactionTooLargeForCache**: 트랜잭션이 cache에 못 들어갈 정도면 abort. 별도 abort 경로 (`transactionLifetimeLimitSeconds` 60초 timeout과 별개)
- **Partial Index의 인덱스 페이지 dirty write**: filter 경계 자주 넘는 필드를 partial index로 잡으면 인덱스 페이지에 dirty write가 발생 — dirty bytes 누적이라는 같은 메커니즘이 다른 경로에서 발현

---

## 참고 — 1차 자료 (전부 fetch 완료)

| 자료 | URL |
|---|---|
| WiredTiger Cache & Eviction Tuning | https://source.wiredtiger.com/mongodb-6.0/tune_cache.html |
| MongoDB `$set` Operator | https://www.mongodb.com/docs/manual/reference/operator/update/set/ |
| Transactions Production Considerations | https://www.mongodb.com/docs/manual/core/transactions-production-consideration/ |
| Replication Source README | https://github.com/mongodb/mongo/blob/master/src/mongo/db/repl/README.md |
| Troubleshoot Replica Sets | https://www.mongodb.com/docs/manual/tutorial/troubleshoot-replica-sets/ |
| Replica Set Data Synchronization | https://www.mongodb.com/docs/manual/core/replica-set-sync/ |
| Replica Set Oplog | https://www.mongodb.com/docs/manual/core/replica-set-oplog/ |
| replSetResizeOplog | https://www.mongodb.com/docs/manual/reference/command/replsetresizeoplog/ |
| MongoDB 8.0 Release Notes | https://www.mongodb.com/docs/manual/release-notes/8.0/ |
| MongoDB 8.0 Compatibility Changes | https://www.mongodb.com/docs/manual/release-notes/8.0-compatibility/ |
