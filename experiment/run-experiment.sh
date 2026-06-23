#!/usr/bin/env bash
# 전체 실험 실행 스크립트
# 사전조건: docker-compose up -d 및 replica set 초기화 완료

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== 1. Replica Set 초기화 ==="
docker exec mongo1 mongosh --quiet --eval '
rs.initiate({
  _id: "rs0",
  members: [
    {_id: 0, host: "mongo1:27017", priority: 2},
    {_id: 1, host: "mongo2:27017"},
    {_id: 2, host: "mongo3:27017"}
  ]
})' 2>/dev/null || true
sleep 5

echo "=== 2. 데이터 시드 ==="
docker exec -i mongo1 mongosh test < "$SCRIPT_DIR/seed.js"

echo ""
echo "=== 3. 시나리오 A (Full Replace) — 랙 측정 ==="
bash "$SCRIPT_DIR/lag-watch.sh" > /tmp/lag-A.log &
LAG_PID=$!
for i in $(seq 1 10); do
  docker exec -i mongo1 mongosh test < "$SCRIPT_DIR/scenario-A-replace.js" > /dev/null
  sleep 2
done
kill $LAG_PID 2>/dev/null
echo "랙 로그: /tmp/lag-A.log"
echo "A 피크 랙: $(grep 'lag=' /tmp/lag-A.log | awk -F'lag=' '{print $2}' | sort -n | tail -1)"

echo ""
echo "=== 4. Oplog 분석 (시나리오 A) ==="
docker exec mongo1 mongosh --quiet local --eval '
db.oplog.rs.aggregate([
  {$match: {"o.applyOps": {$exists: true}}},
  {$sort: {ts: -1}},
  {$limit: 20},
  {$project: {
    ts: 1,
    entryCount: {$size: "$o.applyOps"},
    bsonSizeKB: {$divide: [{$bsonSize: "$$ROOT"}, 1024]},
    partialTxn: "$o.partialTxn"
  }}
]).toArray()'

echo ""
echo "=== 5. 데이터 리셋 ==="
docker exec mongo1 mongosh test --eval 'db.users.drop()' > /dev/null
docker exec -i mongo1 mongosh test < "$SCRIPT_DIR/seed.js" > /dev/null

echo ""
echo "=== 6. 시나리오 B (\$set 부분 업데이트) — 랙 측정 ==="
bash "$SCRIPT_DIR/lag-watch.sh" > /tmp/lag-B.log &
LAG_PID=$!
for i in $(seq 1 10); do
  docker exec -i mongo1 mongosh test < "$SCRIPT_DIR/scenario-B-set.js" > /dev/null
  sleep 2
done
kill $LAG_PID 2>/dev/null
echo "랙 로그: /tmp/lag-B.log"
echo "B 피크 랙: $(grep 'lag=' /tmp/lag-B.log | awk -F'lag=' '{print $2}' | sort -n | tail -1)"

echo ""
echo "=== 결과 요약 ==="
echo "A (Full Replace) 피크: $(grep 'lag=' /tmp/lag-A.log | awk -F'lag=' '{print $2}' | sort -n | tail -1)"
echo "B (\$set)         피크: $(grep 'lag=' /tmp/lag-B.log | awk -F'lag=' '{print $2}' | sort -n | tail -1)"
