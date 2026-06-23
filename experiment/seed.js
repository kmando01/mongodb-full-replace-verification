// Long-tail 분포 시뮬레이션: 1000개 도큐먼트, 5%(index % 20 == 0)가 큰 배열 (~200KB)
db = db.getSiblingDB('test');
db.users.drop();

const docs = [];
for (let i = 0; i < 1000; i++) {
  const isLongTail = i % 20 === 0;
  const historyLen = isLongTail ? 2000 : 50;
  docs.push({
    _id: i,
    name: `user${i}`,
    profile: { age: 30, city: 'Seoul' },
    history: Array.from({ length: historyLen }, (_, k) => ({
      ts: new Date(),
      action: 'click',
      meta: 'x'.repeat(50)
    }))
  });
}

db.users.insertMany(docs);
print('Seeded:', db.users.countDocuments(), 'docs');
print('Normal doc size:', Object.bsonsize(db.users.findOne({ _id: 1 })), 'bytes');
print('Long-tail doc size:', Object.bsonsize(db.users.findOne({ _id: 0 })), 'bytes');
