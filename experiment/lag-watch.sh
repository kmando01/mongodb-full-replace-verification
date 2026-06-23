#!/usr/bin/env bash
# 세컨더리 랙 1초 간격 폴링 — 결과를 stdout으로 출력 (리다이렉트해서 파일 저장)
# 사용: bash lag-watch.sh > lag-A.log &

docker exec mongo1 mongosh --quiet --eval '
while (true) {
  const st = rs.status();
  const primary = st.members.find(m => m.stateStr === "PRIMARY");
  st.members.forEach(m => {
    if (m.stateStr === "SECONDARY") {
      const lag = (primary.optimeDate - m.optimeDate) / 1000;
      print(new Date().toISOString() + " " + m.name + " lag=" + lag + "s");
    }
  });
  sleep(1000);
}'
