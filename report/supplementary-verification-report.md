# 보충 검증 보고서 — 원 검증 보고서 미확인 항목

> 원 검증 보고서(§§1–6)에서 1차 자료 확인이 누락된 5개 항목을 추가 fetch하여 검증한다.
> 각 항목마다 **공식 문서 원문 인용**, **원 보고서 반영 위치**, **영향 평가**를 함께 기록.

---

## 한 줄 결론

**5개 항목 모두 MongoDB 공식 문서로 확정.** 가장 영향이 큰 것은 두 가지:
1. **V1 (MongoDB 8.0 writer/applier 분리)** — 실험을 8.0에서 돌리면 6.x/7.x와 다른 결과, 버전 명시 필수
2. **V3 (secondary snapshot read)** — 원 보고서 §2-1의 "완전 블로킹" 표현이 부정확함을 공식 문서로 확정

| 항목 | 검증 강도 | 원 보고서 영향 |
|---|---|---|
| V1. MongoDB 8.0 writer/applier 분리 | ★★★★★ | §4-9 정정 필요 |
| V2. `transactionLifetimeLimitSeconds` 기본 60초 | ★★★★★ | §7 신규 추가 |
| V3. Secondary snapshot read during replication | ★★★★★ | §2-1 "완전 블로킹" 표현 정정 |
| V4. Oplog capped 한계 초과 성장 (4.0+) | ★★★★★ | §3-2 단위 명시 보강 |
| V5. MongoDB 8.0 `w:majority` 의미 변경 | ★★★★★ | 실험 §4-4 주의사항 추가 |

---

## V1. MongoDB 8.0 writer/applier thread 분리

### fetch 결과 — 공식 문서 원문

**MongoDB 8.0 Release Notes** (직접 확인):

> "Starting in MongoDB 8.0, secondaries write and apply oplog entries for each batch in parallel.
> A writer thread reads new entries from the primary and writes them to the local oplog.
> An applier thread asynchronously applies these changes to the local database.
> This change increases replication throughput for secondaries."

**8.0 Compatibility Changes** (breaking change 명시):

> "This introduces a breaking change for the `metrics.repl.buffer` status metric, as it now provides information on two buffers instead of one."

deprecated 필드 (7.0 이하):
- `metrics.repl.buffer.count`
- `metrics.repl.buffer.maxSizeBytes`
- `metrics.repl.buffer.sizeBytes`

신규 필드 (8.0+):
- `metrics.repl.buffer.write.{count, maxSizeBytes, sizeBytes}` — oplog 수신 대기
- `metrics.repl.buffer.apply.{count, maxCount, maxSizeBytes, sizeBytes}` — 적용 대기

### 원 보고서 §4-9 정정안

**기존 표현 (부정확)**:
> "MongoDB 7.0+에서는 generic batch optimization 덕에 6.0보다 차이 폭이 작아짐"

**정정**:
> **버전 분기 (중요)**: MongoDB 8.0+에서는 secondary가 writer/applier 두 thread로 oplog batch를 병렬 처리한다. 6.x·7.x와 랙 패턴이 달라지므로, 검증 실험은 원문서 incident와 같은 메이저 버전으로 맞춰야 한다.
>
> 8.0에서 병목 위치 측정:
> - `metrics.repl.buffer.write.sizeBytes` — primary → secondary 수신 단계
> - `metrics.repl.buffer.apply.sizeBytes` — secondary 적용 단계 ← chained applyOps 병목은 여기

---

## V2. `transactionLifetimeLimitSeconds` 기본 60초

### fetch 결과 — 공식 문서 원문

**MongoDB Limits and Thresholds** (직접 확인):

> "Transactions have a lifetime limit as specified by `transactionLifetimeLimitSeconds`. The default is 60 seconds."

**Transactions Production Considerations** (직접 확인, 세 가지 abort 경로):

> "By default, a transaction must have a runtime of less than one minute. Transactions that exceed this limit are considered expired and will be aborted by a periodic cleanup process."

> "If you have an uncommitted transaction that causes excessive pressure on the WiredTiger cache, the transaction aborts and returns a **write conflict** error."

> "If a transaction is too large to ever fit in the WiredTiger cache, the transaction aborts and returns a **`TransactionTooLargeForCache`** error."

### 원 보고서 §7 신규 추가

원문서 "45초 랙"의 실제 원인을 세 가지 경로로 분리해야 한다:

| 시나리오 | 원인 | 로그 키워드 | "랙" 의미 |
|---|---|---|---|
| **A** | 트랜잭션 정상 commit + secondary chained replay | 없음 | 실제 replication 지연 (원문서 기술) |
| **B** | 60초 초과 abort → 클라이언트 재시도 누적 | `"abortTransaction"` | abort+재시도 누적, replication은 정상 |
| **C** | WiredTiger cache 초과 abort | `"TransactionTooLargeForCache"` | replication 도달 자체가 안 됨 |

원문서 incident 로그 확인 권고: B·C 키워드가 없으면 시나리오 A(원문서 기술)가 맞음.

**실험 §4-4 영향**: 큰 배열 5개를 한 트랜잭션으로 묶을 경우 60초 한계에 걸릴 수 있다.
→ 실험 시 `db.serverStatus().transactions.totalAborted` before/after 측정을 필수 지표에 추가.

---

## V3. Secondary snapshot read during replication — §2-1 정정

### fetch 결과 — 공식 문서 원문

**Replica Set Data Synchronization** (직접 확인):

> "Read operations that target secondaries and are configured with a read concern level of `"local"` or `"majority"` **read from a WiredTiger snapshot** of the data if the read takes place on a secondary where replication batches are being applied."
>
> "Reading from a snapshot guarantees a consistent view of the data, and allows the read to occur simultaneously with the ongoing replication **without the need for a lock**."

**FAQ: Concurrency** (직접 확인):

> "Reads that target secondaries read from a WiredTiger snapshot of the data if the secondary is undergoing replication. This allows the read to occur **simultaneously with replication**, while still guaranteeing a consistent view of the data."

추가: 동일 문서에서 secondary batch 적용 동작:

> "MongoDB does not apply writes serially to secondaries. Secondaries collect oplog entries in batches and then apply those batches **in parallel**."

### 원 보고서 §2-1 정정

원 보고서 §2-1에서 `applyOps` 공식 문서의 "global write lock" 인용은 **public `applyOps` 명령어**에 대한 기술이며, secondary가 내부 replication에서 oplog batch를 적용하는 동작에는 적용되지 않는다.

공식 문서로 확정된 실제 secondary 동작:
- secondary 내부 replication batch 적용: **병렬(parallel), 읽기 비차단**
- `local`·`majority` read concern: **WiredTiger snapshot에서 즉시 읽기 가능**

**"완전 블로킹" → 정확한 표현**:
- 쓰기: chained applyOps 완료 전까지 동일 `_id`에 대한 write는 직렬 대기
- 읽기: WiredTiger snapshot으로 동시 가능하나, apply가 완료되기 전이면 **stale data 반환**

→ 45초 랙의 실제 영향: "읽기가 멈춘다"가 아니라 "45초 동안 stale data를 보여준다 + write 직렬화"

---

## V4. Oplog는 capped 한계를 초과 성장 가능 (4.0+)

### fetch 결과 — 공식 문서 원문

**MongoDB Replica Set Oplog** (직접 확인):

> "**Unlike other capped collections, the oplog can grow past its configured size limit to avoid deleting the majority commit point.**"

최솟값·최댓값 기본값:
- 최솟값: 990 MB
- 최댓값: 50 GB (free disk의 5%가 50 GB 초과 시)

> "You can specify the minimum number of hours to preserve an oplog entry where `mongod` only removes an oplog entry **if** both of the following criteria are met: the oplog has reached the maximum configured size **AND** the entry is older than the configured number of hours."

### 원 보고서 §3-2 보강

oplog는 4.0부터 설정값이 최댓값이 아닌 **최솟값**으로 동작한다.

| 원문서 표현 | 4.0+ 재해석 |
|---|---|
| "Oplog 윈도우 40분으로 급감" | 윈도우(시간) 단축은 맞으나, **디스크 사용량은 majority commit point 보호로 계속 증가** |
| "세컨더리 탈락 위험" | RECOVERING 진입보다 **디스크 폭증**이 더 즉각적인 위험 |
| "Oplog 윈도우 72시간 회복" | "Oplog bloat 회복"이 더 정확한 표현 |

**§3-2 단위 명시 표 추가 항목**:

| 수치 | 권고 |
|---|---|
| **"Oplog 윈도우 40분 → 72시간"** | 윈도우(`rs.printReplicationInfo()` → `timeDiffHours`)와 디스크 사용량(`db.oplog.rs.stats().size`) 둘 다 기록 필요. 윈도우가 회복돼도 디스크는 계속 늘어나 있을 수 있음. |

---

## V5. MongoDB 8.0 `w:majority` 의미 변경

### fetch 결과 — 공식 문서 원문

**MongoDB 8.0 Compatibility Changes** (직접 확인):

> "Starting in MongoDB 8.0, write operations that use the `"majority"` write concern return an acknowledgment when **the majority of replica set members have written the oplog entry** for the change. This improves the performance of `"majority"` writes. In previous releases, these operations would wait and return an acknowledgment after the majority of replica set members **applied** the change."

### 실험 §4-4 측정의 의미 변경

| 버전 | `w:majority` 반환 시점 | 실험 함의 |
|---|---|---|
| 7.0 이하 | 과반 secondary가 oplog를 **applied** | commit 반환 = 적용 완료 → 이후 랙 측정 가능 |
| **8.0+** | 과반 secondary가 oplog를 **written (received)** | commit 반환 후에도 apply 진행 중 → commit 직후 랙이 자연스럽게 측정됨 |

→ 두 버전을 섞어 A/B 비교하면 안 됨. 실험 docker image 버전을 고정(`mongo:7.0` 또는 `mongo:8.0`)해야 함.

---

## 종합 — 원 검증 보고서 패치 패키지

| # | 위치 | 변경 내용 | 강도 |
|---|---|---|---|
| **P1** | §4-9 전체 교체 | 7.0 이하 / 8.0+ 버전 분기. 8.0 writer/applier 신규 metric 이름 추가 | 필수 |
| **P2** | §2-1 "완전 블로킹" → 표현 정정 | secondary 읽기는 WiredTiger snapshot으로 비차단. "stale data 반환"이 정확한 표현 | 필수 |
| **P3** | §3-2 표에 행 추가 | Oplog 윈도우 vs 디스크 사용량 구분 명시 | 권고 |
| **P4** | §7 신규 추가 | `transactionLifetimeLimitSeconds` 60초 + 시나리오 A/B/C 구분 + `transactions.totalAborted` 측정 | 권고 |
| **P5** | §4-4 시나리오 주의사항 추가 | 8.0 `w:majority` 의미 변경 → 버전 고정 명시 | 권고 |

---

## 참고 — 1차 자료 (이번 보충 검증 fetch 목록)

| 자료 | 확인 항목 |
|---|---|
| https://www.mongodb.com/docs/manual/release-notes/8.0/ | V1: writer/applier 분리, 신규 metrics 필드 |
| https://www.mongodb.com/docs/manual/release-notes/8.0-compatibility/ | V1: deprecated metrics, V5: w:majority 변경 |
| https://www.mongodb.com/docs/manual/reference/limits/ | V2: transactionLifetimeLimitSeconds 60초 기본값 |
| https://www.mongodb.com/docs/manual/core/transactions-production-consideration/ | V2: TransactionTooLargeForCache, write conflict, 60초 abort |
| https://www.mongodb.com/docs/manual/core/replica-set-sync/ | V3: WiredTiger snapshot read, 병렬 batch apply |
| https://www.mongodb.com/docs/manual/faq/concurrency/ | V3: snapshot read 동시성, serial vs parallel |
| https://www.mongodb.com/docs/manual/core/replica-set-oplog/ | V4: oplog capped 초과 성장, majority commit point 보호 |
