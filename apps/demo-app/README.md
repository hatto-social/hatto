# 서버 DB 혼합 스파이크

이 디렉터리는 제품 코드가 아니다. NestJS 서버에서 Postgres(Prisma)와 덱 SQLite 파일을 어떻게 나누는지를 작게 구현하고, 그 쓰기 순서와 읽기 경로가 장애와 동시 읽기에서 버티는지 두드려 보기 위한 스파이크다. `apps/mobile`과 `packages/`는 건드리지 않는다. 여기 코드를 제품 서버로 가져가지 않는다.

측정과 불변식 결과, 그리고 이 구조에서 드러난 구멍은 [REPORT.md](REPORT.md)에 있다. 그 문서의 숫자는 이 저장소를 만든 환경에서 실제로 명령을 돌려 얻은 값이다.

## 무엇을 고정했는가

Postgres는 사용자, ACL, ActivityPub 형태의 활동 기록, 덱 메타데이터, 버전 포인터, outbox의 정본이다. 카드와 필드와 hist는 덱 SQLite 파일에만 있다. 덱 파일에는 Prisma를 쓰지 않고 `better-sqlite3`와 고정 SQL을 쓴다. `PrismaService`와 `DeckStore`는 모듈이 나뉘어 있고, 한 트랜잭션이 두 저장소를 넘지 않는다.

안전한 기본 경로는 버전마다 새 파일을 만든다. 임시 파일에 본문을 쓰고 fsync한 뒤 rename하고, 무결성을 확인한 다음에야 Postgres 트랜잭션에서 포인터와 outbox와 활동 기록을 함께 커밋한다. 그 트랜잭션이 실패하면 포인터는 이전 파일을 가리키고, 새 파일은 고아로 남는다. 비교용으로 같은 파일을 제자리에서 고치는 WAL 경로와, 임시 파일을 같은 경로 위로 rename하는 경로도 들어 있다. 읽기 캐시는 버전 키와 덱 id 키 두 가지다.

## 돌리는 법

Postgres가 로컬에 있어야 한다. 이 스파이크를 돌린 VM에는 Docker가 없어서 testcontainers를 쓰지 못했다. Ubuntu 패키지의 PostgreSQL 16을 소켓 peer 인증으로 붙였다.

```sh
# 한 번
sudo apt-get install -y postgresql postgresql-contrib build-essential
sudo service postgresql start
sudo -u postgres psql -c "CREATE ROLE ubuntu WITH LOGIN SUPERUSER"
sudo -u postgres createdb -O ubuntu hatto_spike
```

`apps/demo-app`에서:

```sh
npm ci
npm test
npm run stress
```

`DATABASE_URL`의 기본값은 `.env.example`에 있다. `npm test`는 장애 주입과 불변식이고, `npm run stress`는 다수 읽기, LRU, WAL, 큰 덱이다. 테스트는 `--test-concurrency=1`이다. 둘은 같은 데이터베이스를 비우고 쓰므로 겹쳐 돌리지 않는다.

결과 요약은 `results/summary.json`과 `results/checks.json`에 남는다. `dist/`와 덱 파일은 커밋하지 않는다.
