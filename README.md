# MongoDB Full Replace 안티패턴 — 주장 검증 보고서

MongoDB Full Replace 패턴이 세컨더리 랙을 유발한다는 주장의 메커니즘을 MongoDB 공식 문서 및 소스 코드로 대조 검증하고, 핵심 수치(세컨더리 랙 45초)를 재현 가능한 형태로 실험 설계한 레포지토리.

## 구성

```
README.md                          ← 이 파일
report/
  verification-report.md           ← 메인 검증 보고서 (메커니즘 대조 + 수치 평가 + 실험 설계)
experiment/
  docker-compose.yml               ← 3-node replica set 환경
  seed.js                          ← Long-tail 분포 데이터 시드
  scenario-A-replace.js            ← Full Replace (안티패턴)
  scenario-B-set.js                ← $set 부분 업데이트 (개선안)
  lag-watch.sh                     ← 세컨더리 랙 1초 간격 폴링
  run-experiment.sh                ← 전체 실험 실행 스크립트
```

## 한 줄 결론

메커니즘은 공식 문서·소스 코드로 모두 확정. 정량 수치(45초)는 메커니즘상 plausible하나 환경 종속 — 위 실험으로 1시간 내 직접 재현 가능.

## 빠른 실행

```bash
docker-compose -f experiment/docker-compose.yml up -d
sleep 10
bash experiment/run-experiment.sh
```
