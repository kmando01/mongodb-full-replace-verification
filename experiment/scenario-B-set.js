// 시나리오 B: $set 부분 업데이트 (개선안)
// long-tail 도큐먼트 5개를 하나의 트랜잭션으로 변경 필드만 업데이트 → oplog에 필드 하나만 기록
const session = db.getMongo().startSession({ causalConsistency: false });
const coll = session.getDatabase('test').users;

try {
  session.startTransaction({ writeConcern: { w: 'majority' } });
  for (const id of [0, 20, 40, 60, 80]) {
    const doc = coll.findOne({ _id: id }, { projection: { history: 1 } });
    const lastIdx = doc.history.length - 1;
    coll.updateOne(
      { _id: id },
      { $set: { [`history.${lastIdx}.action`]: 'updated' } }
    );
  }
  session.commitTransaction();
} catch (e) {
  session.abortTransaction();
  throw e;
} finally {
  session.endSession();
}
