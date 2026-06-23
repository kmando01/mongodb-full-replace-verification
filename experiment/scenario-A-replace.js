// 시나리오 A: Full Replace (안티패턴)
// long-tail 도큐먼트 5개를 하나의 트랜잭션으로 전체 교체 → oplog에 배열 전체 인라인
const session = db.getMongo().startSession({ causalConsistency: false });
const coll = session.getDatabase('test').users;

try {
  session.startTransaction({ writeConcern: { w: 'majority' } });
  for (const id of [0, 20, 40, 60, 80]) {
    const doc = coll.findOne({ _id: id });
    doc.history[doc.history.length - 1].action = 'updated';
    coll.replaceOne({ _id: id }, doc);
  }
  session.commitTransaction();
} catch (e) {
  session.abortTransaction();
  throw e;
} finally {
  session.endSession();
}
