# Postgres 포인터와 덱 SQLite를 같이 쓰는 스파이크

이 디렉터리는 제품 서버가 아니다. 사용자·ACL·활동 기록·덱 메타데이터와 버전 포인터는 Postgres에 두고, 카드·필드·hist는 덱마다 SQLite 파일에 두며, 덱 파일을 먼저 쓴 다음 포인터를 커밋한다는 구성을 작게 구현해 장애와 동시 읽기에서 깨지는 곳을 찾기 위한 실험이다. `apps/mobile`과 `packages`는 바꾸지 않았다. 아래 숫자는 이 VM에서 명령을 돌려 나온 값이고, 명령을 돌리지 않은 해석은 추정이라고 적었다.

## 환경과 명령

Docker가 설치되어 있지 않았다. testcontainers는 쓰지 못했고, Ubuntu 패키지의 PostgreSQL 16.15를 유닉스 소켓 peer 인증으로 붙였다. 연결 문자열은 `postgresql://ubuntu@localhost/hatto_spike?host=/var/run/postgresql`이다. SQLite는 `better-sqlite3` 12.11.1이 묶어 온 3.53.2이다. 배포판의 `sqlite3` 3.45.1과는 다른 라이브러리다. 기계는 Linux 6.12, CPU 4개(Intel Xeon), 메모리 16GB, Node v22.23.4이다.

불변식 테스트는 `apps/demo-app`에서 `npx tsc -p tsconfig.json && node --test --test-concurrency=1 dist/test/*.test.js`로 돌렸다. 30개가 통과하고 실패한 테스트는 없었다. 테스트 러너가 보고한 시간은 9.03초이다. 여기서의 통과는 실험이 의도한 대로 재현됐다는 뜻이다. 같은 경로를 덮어써서 포인터가 깨지는 경우처럼, 불변식이 실패하는 실험도 그 실패를 확인하는 테스트로 통과시켜 두었다.

스트레스는 `npm run stress`이다. 벽시계 50.4초이고, 그 안에 Prisma 생성과 마이그레이션, `tsc`가 들어 있다. 시나리오 본체는 2026-11-12T09:24:28.606Z부터 09:25:15.980Z까지다. 종료 코드는 0이다. 시나리오 함수가 예외를 던지지 않았다는 뜻이지, 모든 불변식이 성립했다는 뜻은 아니다. 원본은 `results/summary.json`, `results/checks.json`, `results/cost.json`이다.

30,000장 덱에서 복사와 fsync와 `integrity_check`를 나누어 재기 위해 스트레스 뒤에 한 번 더 돌린 명령이 있다. `dist/src/deck-store/sqlite.js`의 `buildTempFile`, `copyFileSync`, `fsyncPath`, `integrityOf`, `mutateInPlace`를 `/tmp`의 임시 디렉터리에서 호출했다. 그 결과가 `results/cost.json`이다.

## 구현이 고정한 경로

Postgres 스키마는 Prisma datasource가 하나이고 provider는 postgresql이다. 카드, 필드, hist 테이블은 Postgres에 없다. 덱 본문은 `better-sqlite3`와 고정 SQL이고, 스키마 버전은 `PRAGMA user_version`이다. `PrismaService`와 `DeckStore`는 Nest 모듈이 나뉘어 있고, 포인터를 커밋하는 트랜잭션은 Postgres 안에서만 열린다.

안전한 기본 쓰기는 버전마다 새 파일을 만든다. 임시 파일에 본문을 쓰고, 파일을 fsync하고, rename하고, 디렉터리를 fsync하고, `integrity_check`가 `ok`인 다음에야 Postgres 트랜잭션에서 포인터와 버전 행과 outbox와 활동 기록을 함께 갱신한다. 포인터 갱신은 `current_version`이 기대한 값일 때만 통과한다. 활동 기록의 payload는 버전, 해시, 바이트 수, 카드 수, hist 수뿐이다.

비교를 위해 두 길을 더 두었다. `mutable`은 덱당 `deck.sqlite` 하나를 WAL로 제자리에서 고친다. `replace`는 임시 파일에 새 내용을 만든 뒤 같은 `deck.sqlite` 경로 위로 rename한다. 읽기 캐시는 버전 키와 덱 id 키 두 가지다. `better-sqlite3` 12는 `SQLITE_OPEN_URI`를 넘기지 않아서 `immutable=1`을 이 드라이버로 열 수 없다. 불변 파일의 읽기 핸들은 `readonly: true`에 `query_only`를 더한 것이다. `immutable=1`은 Node 내장 `node:sqlite`로만 따로 열었다.

## 읽기 경로

불변 파일에서는 포인터가 바뀌는 동안 읽기가 한 버전 안에 머물렀다. 40장짜리 덱을 주인이 150ms마다 새 버전으로 올리는 동안, 읽기 스레드 1, 4, 16, 32개가 각각 2.5초 동안 포인터를 다시 읽고 그 경로만 열었다. 네 경우 모두 오류 0, 버전 섞임 0, 포인터와 파일 해시가 어긋난 횟수 0이다. 스레드는 여러 버전을 보았지만 한 번의 읽기가 두 버전을 섞지는 않았다. 지연은 각 워커가 모은 전체 표본의 nearest-rank이고, 표본을 버리지 않았다(`sampled: false`).

| 읽기 스레드 | 읽기 수 | 초당 처리 | p50 | p99 | 최댓값 | 포인터 커밋 p50 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 10790 | 4316 | 0.20ms | 0.74ms | 4.89ms | 6.79ms |
| 4 | 21126 | 8450 | 0.42ms | 1.66ms | 11.3ms | 10.0ms |
| 16 | 17421 | 6968 | 1.88ms | 8.81ms | 37.5ms | 19.8ms |
| 32 | 18403 | 7361 | 3.08ms | 22.7ms | 117ms | 40.9ms |

4스레드에서 처리량이 가장 높았고, 16과 32에서는 p99가 크게 늘었다. 이 기계의 CPU는 4개다. 포인터 커밋도 읽기가 늘수록 느려졌다. 새 버전은 서로 다른 파일이라 SQLite 쓰기 잠금이 읽기와 겹치지는 않는다. 느려진 쪽이 Postgres인지 CPU인지는 분리해서 재지 않았다.

같은 조건에서 덱 32개를 읽기 32개가 나누어 읽으면, 쓰기가 없을 때 2.5초 동안 읽기 21865회, 초당 6602, p50 3.31ms, p99 14.5ms, 오류 0, 섞임 0이었다. 한 덱에 32개가 몰린 경우보다 처리량은 낮고 p99는 짧다. 인기 덱이 처리량을 무너뜨리지는 않았고, 꼬리 지연을 늘렸다.

제자리 갱신은 그 불변식을 지키지 못했다. 8개 스레드가 한 덱을 2.5초 동안 읽고, 각 읽기는 SQLite 트랜잭션 하나로 본문을 봤다. 주인이 지연 없이 계속 커밋할 때 읽기 14395회 중 9070회(63.0%)가 포인터의 버전·해시와 다른 파일을 봤다. 트랜잭션 안에서 본문이 두 버전으로 섞인 횟수는 0이다. Postgres 커밋 앞에 `pg_sleep(30ms)`를 넣으면 14628회 중 12750회(87.2%)가 어긋났고, 섞임은 여전히 0이다. 지연을 넣지 않아도 창은 넓었다. 파일 커밋과 포인터 커밋 사이의 간격이 로컬 디스크에서도 읽기보다 길다.

트랜잭션 없이 여러 문장으로 읽게 하면 섞임이 실제로 나온다. 같은 30ms 지연에서 읽기 14095회 중 포인터와 어긋난 것이 12520회이고, 한 읽기 안에서 manifest와 hist의 버전이 갈라진 것이 75회이다. 결정적으로 재현한 분할 읽기에서는, manifest를 읽은 뒤 부모가 제자리 커밋하고 이어서 hist를 읽으면 `mixed: true`, manifest 버전 1, hist의 최대 rev 2였다. 같은 분할을 트랜잭션으로 감싸면 `mixed: false`였다. 불변 파일에서 같은 분할을 하면, 포인터가 새 파일로 옮겨도 이미 연 파일의 두 번째 조회는 버전 1 그대로였다.

같은 경로 위로 rename하는 `replace`도 포인터 불일치를 막지 못한다. 8스레드, 30ms 지연, 트랜잭션 읽기에서 17778회 중 15315회(86.1%)가 어긋났고 섞임은 0이다. rename은 페이지가 찢긴 파일을 노출하지는 않지만, 경로가 같아서 포인터가 가리키기 전에 새 내용이 그 경로에 있다.

캐시는 키에 따라 갈린다. 경로와 해시로 키를 주면, 같은 버전의 두 번째 읽기는 캐시이고 포인터와 맞다. 버전이 올라가면 그 키는 빗나간다. 덱 id만으로 키를 주면 새 버전을 올린 뒤에도 이전 본문을 돌려주고, 그때 포인터는 3인데 캐시는 2였다. 프로세스 안에서 이미 가진 객체를 1초 동안 다시 만지기만 하면 17,925,864회, 회당 0.000056ms이다. 포인터를 매번 Postgres에서 읽고 본문만 캐시하면 1초에 2195회, 회당 0.46ms이다. 캐시 없이 포인터와 SQLite를 모두 읽으면 1367회, 회당 0.73ms이다. 본문 캐시가 줄이는 시간은 0.3ms 안쪽이고, 포인터 조회가 남아 있다. 포인터까지 캐시하면 그 0.46ms가 더 줄겠지만, 덱 id 캐시와 같이 오래된 버전을 돌려주게 된다.

읽기 한 번의 시간을 포인터와 본문으로 나누면, 쓰기가 없는 40장 덱에서 8스레드 2초 기준 둘 다 초당 7241(p50 0.98ms), 포인터만 초당 32373(p50 0.16ms), 본문만 초당 30193(p50 0.12ms)이다. 로컬 소켓이라 네트워크 왕복은 없다. 먼 Postgres라면 포인터 쪽에 그 왕복이 더해질 것이다. 이것은 추정이다.

`node:sqlite`의 `immutable=1`은 이미 연 연결이 rename 뒤에도 버전 1을 봤고, 새로 연 연결은 버전 2를 봤다. 열린 핸들은 이전 inode에 머물렀다. 이 동작은 읽던 사람에게는 안정적이지만, 경로가 하나인 한 새로 여는 읽기는 포인터보다 앞선 내용을 본다. `better-sqlite3`로는 이 플래그를 켜지 못했다.

## 불변식

프로세스 kill은 자식 프로세스가 지정한 지점에서 `SIGKILL`을 받게 했다. 전원 차단이나 디스크 캐시 유실은 재현하지 않았다. 여덟 지점 모두 포인터는 열 수 있는 파일의 버전·해시와 맞았고, 그 버전의 outbox는 하나였다.

| 지점 | 포인터 버전 | 고아 파일 | 임시 파일 |
| --- | ---: | ---: | ---: |
| 임시 파일 기록 후, fsync 전후, rename 전 | 1 | 0 | 1 |
| rename 후, 포인터 트랜잭션 전, 트랜잭션 안 | 1 | 1 | 0 |
| 포인터 커밋이 반환된 뒤 | 2 | 0 | 0 |

커밋이 반환되기 전에 죽으면 포인터는 이전 파일에 남고 outbox도 이전 버전만 있다. 트랜잭션 안에서 예외를 던져도 같다. 커밋 뒤에 죽으면 포인터와 outbox와 파일이 함께 2로 있다. outbox를 포인터와 같은 트랜잭션에 넣으면, 커밋된 포인터에 행이 없고 롤백된 포인터에 행이 있는 상태는 나오지 않았다. 트랜잭션이 `pg_sleep` 중일 때 다른 연결에서 본 포인터는 아직 1이고 outbox 버전 2의 개수는 0이었으며, 디스크의 `v2-` 파일은 이미 manifest 버전 2였다. 포인터를 따르는 읽기는 그 파일을 열지 않는다. 디렉터리를 읽을 수 있는 주체는 커밋 전에 다음 버전을 볼 수 있다. 파일 권한은 ACL이 아니다.

outbox 행을 소비자에게 넘긴 뒤 `delivered_at`을 찍기 전에 멈추면, 다시 집어 올 때 효과가 두 번 실행됐다. 표시가 된 뒤에는 두 번째 전달이 `already`이고 효과는 다시 돌지 않는다. 행 자체는 `(deck, version, type)` 유니크로 한 번만 생긴다. 유실은 포인터 기준으로 없었고, 중복은 전달 쪽에 있다.

무결성 검사를 건너뛰고 SQLite 매직 바이트를 덮어쓴 파일을 포인터에 커밋하면, 포인터는 존재하지 않는 것이 아니라 열리지 않는 파일을 가리킨다. 검사는 그 커밋을 `CorruptFileError`로 막고 포인터를 1에 남겼다. 매직을 덮어쓴 것은 전원 장애의 재현이 아니라, 커밋 전에 파일이 깨져 있는 상태를 만든 것이다.

grace 0인 GC가 포인터 커밋 직전에 그 파일을 지우면, 트랜잭션 안의 존재 확인이 커밋을 취소하고 포인터는 1에 남는다. 그 확인이 없는 채로, 커밋 전에 찍어 둔 경로 목록으로 GC를 돌리면 방금 커밋된 파일을 지우고 포인터는 없는 경로를 가리킨다. 커밋된 버전 행을 다시 읽고 grace 0으로 지우면, 방금 만든 고아는 사라지고 현재 파일은 남는다. grace를 60초로 두면 방금 만든 고아는 아직 지워지지 않는다. 고아를 즉시 없애는 일과, 쓰기가 끝나기 전에 그 파일을 지우지 않는 일은 같은 grace로 동시에 만족하지 않는다.

이전 버전을 연 읽기 8개는, 포인터가 다음 버전으로 옮고 naive GC가 이전 경로를 unlink한 뒤에도 8개 모두 버전 1을 다시 읽었다. 그 경로를 새로 열면 `unable to open database file`이다. Linux에서는 열린 fd의 inode가 남아서, 이미 읽던 사람은 살리고 새로 여는 사람은 실패한다. 버전 행은 지워진 경로를 계속 가리킨다. 만료 전 lease가 있으면 같은 GC가 그 경로를 unlink하지 않았고, lease를 푼 뒤에야 지웠다. 읽기마다 lease를 넣고 빼면 회당 0.80ms가 1.77ms가 되었다. 로컬 Postgres 기준 약 2.2배이다. lease를 남긴 채 끝난 행은 0이었다.

같은 `vN.sqlite` 경로로 두 프로세스가 쓰게 하면, 먼저 커밋한 쪽의 해시를 포인터가 기억한 뒤 나중 프로세스가 그 파일을 덮어쓰고 CAS에서 탈락한다. 포인터의 해시와 파일의 해시가 달라 불변식은 실패했다. 경로에 토큰을 붙이면 같은 타이밍에 진 쪽은 고아 파일 하나만 남기고, 포인터는 이긴 파일과 맞았다. 전용 연결의 `pg_advisory_lock`은 두 프로세스를 직렬화해 버전 2와 3이 둘 다 커밋됐고 고아는 없었다. 같은 락을 Prisma 풀로 여덟 갈래에 걸고 풀면, 풀 연결에 advisory 락이 8개 남았다. 세션 락은 잠근 연결과 푸는 연결이 같아야 하는데 풀은 그걸 보장하지 않는다. 전용 연결은 잡는 동안 1, 푼 뒤 0이었다. 트랜잭션 안에서 advisory 락을 잡은 자식을 kill한 뒤, 부모가 같은 덱을 다시 올릴 수 있었다. 연결이 끊기면 락은 풀린다.

ACL 행을 지운 소유자는 `owner_id`가 그대로여도 쓰기가 거절됐다. 인가의 정본은 ACL 행이다. `owner_id`는 그 사실의 두 번째 사본이라 둘이 어긋날 수 있다.

한 번의 응답이 두 번의 성공한 읽기를 이어 붙이면, 불변 파일에서도 카드는 버전 1이고 hist는 버전 2인 본문을 만들 수 있다. 저장소가 막아 주지 않는다. 읽기는 포인터를 한 번만 보고 그 경로만 써야 한다.

## 운영에서 보인 것

WAL을 공유하는 파일은 읽기가 체크포인트를 막는다. 자동 체크포인트를 끄고 읽기 트랜잭션 2개를 연 채 40번 쓰면 WAL이 494,432바이트까지 자라고, `PASSIVE`는 120프레임 중 0을 체크포인트했다. `TRUNCATE`는 301ms 뒤에 `busy=1`을 반환하고 WAL은 그대로였다. 읽기를 놓은 뒤 `TRUNCATE`는 2.74ms에 끝났고 WAL은 0이었다. 읽기가 없는 같은 쓰기 40번은 체크포인트 후 WAL 0이었다. 읽기 8개와 쓰기 200번에서는 WAL이 2,472,032바이트, 로그 600프레임이었고 `TRUNCATE`는 301.6ms 만에 `busy=1`이었다. 읽기를 놓자 2.48ms에 WAL이 0이 됐다. `busy_timeout`을 300ms로 두었으므로, 대기는 그 한도에 걸린 것이다.

마지막 연결이 닫힐 때 SQLite는 WAL을 체크포인트한다. 그래서 읽기가 없으면 파일을 닫는 것만으로 `-wal`이 사라진다. 다른 연결이 열려 있으면 닫아도 WAL이 남고, 본 파일만 복사하면 최신 커밋이 빠진다. 시드 뒤에 읽기 트랜잭션을 하나 잡고 hist 한 줄을 추가한 뒤 본 파일만 복사하면 hist 0, manifest 버전 1이었다. 읽기를 놓고 `wal_checkpoint(TRUNCATE)`한 뒤 복사하면 hist 1, 버전 2였다. 그때 WAL은 12,392바이트였다. 업로드 전에 체크포인트하라는 규칙은, 읽기가 없는 파일에서는 닫기만으로도 만족되고, 읽기가 있는 파일에서는 최신 내용을 넣으려면 그 읽기가 끝날 때까지 기다리거나 실패한다. 불변 파일은 발행 전에 DELETE 저널로 봉인하므로 읽기와 WAL을 공유하지 않는다.

덱 파일 2500개를 만들고 Postgres에 포인터와 outbox와 ACL을 넣었다. 파일 하나는 32,768바이트, 합은 81,920,000바이트이다. 만드는 데 6.10초, insert에 0.55초였다. 4MB LRU로 모두 열었다 놓으면 핸들 128개, 축출 2372회, 스캔 103ms, 끝난 뒤의 sqlite fd도 128개였다. 표본 30개의 해시는 포인터와 맞았고, 첫 파일을 다시 여는 데 0.30ms였다. 상한보다 큰 파일 하나도 핸들 1개로 열렸고 상한을 넘긴 채로 남았다. 핀이 걸린 핸들은 축출되지 않았다. 이 LRU는 프로세스 하나 안의 것이다. 워커 스레드의 핸들은 여기 포함되지 않는다.

30,000장 발행의 끝에서 끝까지 시간은 불변 파일이 생성 222ms, hist 한 줄 추가 105ms, 파일이 4,661,248바이트였다. 제자리 갱신은 생성 211ms, 추가 98ms로 거의 같았다. 둘 다 발행 전에 `integrity_check`를 돈다. 그 검사를 분리하면 그림이 달라진다. 3,899,392바이트짜리 30,000장 파일을 새로 만드는 데 239ms, 복사 3.91ms, fsync 0.52ms, `integrity_check` 24.8ms였다. 같은 크기 파일을 제자리에서 hist 한 줄만 고치는 데 74.8ms였고, 이 시간은 연결을 닫으며 WAL을 체크포인트하는 것까지 포함한다. 이 크기에서는 복사 비용이 무결성 검사보다 작았다. 불변 버전이 항상 제자리 갱신보다 비싸다는 결론은 이 측정에서 나오지 않았다.

8,000장을 한 프로세스에서 올리는 동안 5ms 타이머의 최대 간격은 58.4ms였고 발행은 62.2ms였다. 이벤트 루프가 발행 거의 전부 동안 멈췄다. 10,000장 파일을 복사해 다음 버전으로 올리는 44ms 동안에도 부모 루프의 최대 간격은 35.5ms였다. 그 사이 다른 스레드의 읽기 4개는 오류와 섞임과 포인터 불일치가 없었다. 다만 그 647회는 모두 버전 2만 봤다. 워커가 Postgres에 접속하는 시간이 44ms 발행보다 길어서, 복사 도중의 버전 1을 표본으로 잡지 못한 것이다. 복사 도중에도 한 버전만 보이는지는 40장 덱을 반복 발행한 측정이 보여 준다. 큰 파일에서 겹친 구간은 이번 실행으로 확인하지 못했다.

오래된 `user_version` 1 파일을 읽기 트랜잭션이 연 채 그 파일에 마이그레이션을 적용하면 `database is locked`이고 버전은 1에 남는다. 그 파일을 복사한 새 버전에 마이그레이션을 적용하면 원본은 1, 새 파일은 2이고 hist 1행이 생긴다. 읽기 전용으로 연 연결은 `ALTER`를 할 수 없다. 열 때 지연 적용은 읽기 연결과는 같이 가지 않는다.

## 비어 있던 부분

덱마다 파일이 하나라는 말과, 새 버전을 먼저 쓰고 포인터를 나중에 커밋한다는 말은 그대로 두면 충돌한다. 한 파일을 제자리에서 고치면 포인터가 갱신되기 전에 그 경로의 내용이 바뀌고, 이번 실행에서는 지연이 없어도 읽기의 63%가 그 창에 걸렸다. 포인터가 이름 하는 바이트가 항상 그 포인터의 것이려면, 버전은 고유한 경로의 새 파일이고 포인터는 그 경로와 해시를 가져야 한다. 이전 파일은 다음 GC까지 남는다. 그것이 덱당 하나의 현재 파일이다.

그 파일은 임시 경로에 쓰고 fsync한 뒤 rename하고 디렉터리를 fsync한다. 이번 kill은 프로세스 죽음이지 전원 차단이 아니라서, fsync를 빼면 커널 페이지 캐시가 어떤 바이트를 잃는지는 측정하지 않았다. 측정한 것은, 커밋 전에 파일이 깨져 있으면 무결성 검사가 포인터를 막는다는 것과, 검사가 없으면 포인터가 깨진 파일을 가리킨다는 것이다. 존재 확인은 포인터 트랜잭션 안에 있어야 한다. 커밋 전에 찍어 둔 경로 목록으로 지우는 GC는 방금 커밋된 파일을 지운다.

GC가 지울 고아는 커밋된 버전 행이 가리키지 않고, 발행에 필요한 시간보다 오래된 파일이다. 현재 포인터만 남기고 나머지를 지우면 이전 버전을 읽던 fd는 Linux에서 당장은 살지만, 새로 여는 읽기는 실패하고 버전 행은 깨진 경로가 된다. 읽기마다 Postgres lease를 쓰면 그 창은 닫히고, 로컬에서 읽기 비용이 약 2.2배가 된다. 이전 버전 하나를 grace와 함께 남기는 쪽이 핫 덱에는 싸다. lease를 쓴다면 TTL은 열기까지의 시간만 덮고, 이미 연 fd가 읽는 시간은 inode가 덮는 편이 맞다. 프로세스가 죽으면 fd는 바로 풀리지만, 긴 lease는 GC를 그 TTL 동안 막는다.

같은 덱의 잠금이 프로세스 메모리에만 있으면 두 번째 프로세스를 막지 못한다. 경로가 고유하고 포인터가 CAS이면 진 쪽은 고아만 남긴다. 경로를 공유하면 CAS가 져도 이긴 파일을 덮어쓴다. advisory 락은 낭비되는 파일 쓰기를 줄이는 용도이고, Prisma 풀에 세션 락을 올리면 락이 샌다. 전용 연결이어야 한다.

outbox는 포인터와 같은 트랜잭션이면 행의 유실과 중복은 없었다. 전달은 표시 전에 죽으면 두 번 실행된다. 소비자는 `(deck, version, type)`으로 효과를 한 번만 적용해야 한다.

읽기 전용 핸들로 옛 `user_version`을 고칠 수 없다. 마이그레이션은 다음 버전 파일을 만들 때 하고, 이미 발행된 파일은 그대로 읽히게 두는 편이 읽기와 맞다.

핸들 LRU는 핀이 있는 fd를 닫지 않아야 하고, 상한보다 큰 파일 하나는 열어야 한다. 상한은 프로세스마다이다. `better-sqlite3` 호출은 그 스레드를 막는다. 큰 발행은 그 프로세스의 다른 요청도 같이 멈춘다. 읽기를 다른 스레드에 두면 그 정지는 읽기로 번지지 않았고, 불변 파일에서는 버전 섞임도 없었다.

본문 캐시는 버전 키일 때만 포인터와 맞다. 포인터 조회를 빼지 않으면 핫 덱의 시간에서 큰 부분은 Postgres에 남는다. 포인터를 오래 캐시하면 읽기는 이전 버전을 본다. 그 지연을 허용할지는 이번 실험 밖의 제품 결정이다.

## Fedify로 덱 rev를 주고받기

이 절은 `@fedify/fedify` 2.4.5를 고정해, origin이 다른 인스턴스 두 개를 `127.0.0.1`의 빈 포트에 띄우고 실제로 POST한 결과다. 스냅샷 바이트는 S3나 MinIO가 아니라 같은 머신의 정적 파일 서버가 내보냈다. Docker가 없어 그 둘을 띄우지 못했다. 파일 서버는 공개 객체는 경로만으로 주고, 비공개 객체는 `exp`와 HMAC `sig`가 맞고 만료 전일 때만 준다. 측정 명령은 `npx tsc -p tsconfig.json && node --test --test-concurrency=1 dist/test/fedify.test.js`이고, 그 단독 실행은 3.93초였다. 이어서 돌린 `npm test` 31개 중 이 테스트는 3.57초였고, 아래 시계 시각은 그 실행의 `results/fedify.json`이다. 원본은 `results/fedify.json`이다. 아래 상태 코드와 필드 유무는 그 실행에서 받은 응답이다.

`sendActivity`는 활동을 보내기 전에 `toJsonLd({ format: "compact" })`로 다시 만든다. 이 경로는 알고 있는 어휘 필드만 남긴다. 객체 디스패처는 `toJsonLd`에 format을 넘기지 않아서, `fromJsonLd`가 캐시한 원문 JSON이 그대로 나간다. 그래서 같은 문서라도 보내는 함수가 다르면 `hatto:` 필드의 운명이 갈린다.

공개 덱 rev 2는 Update의 `object`에 객체를 넣지 않고 `/decks/{guid}/revs/2` URI만 넣었다. Activity id는 그 guid와 rev로 고정했고, `orderingKey`에는 guid를 넣었으며 `immediate: true`라 큐는 없었다. 받는 인박스는 202를 한 번 반환했다. 와이어의 object는 URI 문자열이었고 `hatto:` 키는 없었다. 그 URI를 서명 없이 GET하자 200이었고, 본문에 `type: ["hatto:Deck", "Object"]`, `hatto:rev: 2`, `hatto:guid: "public-deck"`, `url.type: "Link"`, `mediaType: "application/octet-stream"`, `digestMultibase`가 그대로 있었다. 받는 쪽 `lookupObject`가 다시 읽은 JSON도 같은 필드였다. Link의 href로 정적 파일 서버를 GET하자 200, 본문 18바이트였고, 그 바이트의 SHA-256을 multibase `u`로 인코딩한 값이 `digestMultibase`와 같았다.

대조군은 두 가지다. 타입이 문자열 `"hatto:Deck"` 하나인 객체를 임베드한 Update는 `fromJsonLd`가 `Invalid type: hatto:Deck`으로 거절했다. 그 JSON을 서명한 POST로 인박스에 넣자 400이었고 본문은 `Invalid activity.`였다. 타입을 `["hatto:Deck", "Object"]`로 하고 `hatto:rev`를 넣은 뒤 `sendActivity`로 보내면, compact 결과는 `type: "Object"`와 `id`, `name`만 남고 `hatto:rev`는 null이었다. 인박스는 202였고, 리스너가 본 임베드 객체에도 `hatto:` 필드는 없었다. 같은 배열 타입과 `hatto:rev`, `hatto:guid`를 원문 JSON 그대로 다른 Activity id로 서명 POST하자 인박스는 202였고, 리스너가 파싱한 객체에는 타입 배열과 `hatto:rev: 2`, `hatto:guid: "embed"`가 남아 있었다. 받는 파서는 배열 타입과 확장 필드를 버릴 수 있다. 지우는 쪽은 `sendActivity`의 compact다.

소셜 이벤트를 `Create{Note}`에 싣고 Hatto 데이터는 `hatto:` 확장 속성에 둔다는 전제는, 이 버전의 `sendActivity`와는 맞지 않는다. Note에 `hatto:deck`, `hatto:event`, `hatto:streakDays: 12`, `hatto:reviewCount: 40`, `hatto:measurementSource: "self-reported-device"`를 넣고 compact하면 남은 키는 `id`, `type`, `content`뿐이었다. 그 Create를 보내면 인박스는 202였고 와이어의 임베드 객체에 `hatto:` 키는 0개였다. 수신 측은 그 숫자를 복원할 수 없다.

같은 내용을 표준 필드에 옮겨 compact하면 남는다. `tag`는 Link로 href와 name `deck-published`가 있고, `url`은 Link로 href와 `mediaType: "application/activity+json"`과 name `deck`이 있다. `attachment`는 `http://schema.org#PropertyValue`이고 name은 문자열 `hatto:event`, 값은 `deck-published`다. 스키마 용어가 짧은 이름으로 줄지는 않았지만 값 자체는 와이어에 있다. 이 방식으로는 덱 IRI와 이벤트 이름을 전달할 수 있다. `hatto:streakDays` 같은 확장 속성이 수신 객체의 필드로 살아 있는 것은 아니다.

그 필드가 살아남은 경로는 디스패처다. Create의 object를 Note URI만 두고, `/notes/{id}` 디스패처가 원문 JSON을 `fromJsonLd`로 만들어 반환하게 하자 GET은 200이었고 `hatto:deck`, `hatto:event`, `hatto:streakDays`, `hatto:reviewCount`, `hatto:measurementSource`가 모두 있었다. 받는 인스턴스의 `lookupObject`도 같은 다섯 필드를 돌려줬다. 따라서 Create{Note}로 연합한다는 문장은 이렇게 고치는 편이 측정과 맞다. `sendActivity`가 compact하는 Note에는 `content`와 `tag`, `attachment`, `url`만 둔다. `hatto:deck`, `hatto:event`, 횟수, 측정 출처는 그 Note에 넣지 말고, 서버 디스패처가 원문으로 내보내는 객체의 필드로 둔 뒤 Create나 Update는 그 객체의 URI만 보낸다. 단일 타입 `hatto:Deck`을 Update에 임베드하는 길은 400이라 쓸 수 없다. 배열 타입을 임베드해도 `sendActivity`가 compact하는 순간 확장 필드는 사라진다.

미리 로드되지 않은 `@context` URL은 파싱을 멈춘다. `https://hatto.invalid/ns.jsonld`를 컨텍스트에 넣자 `Dereferencing a URL did not result in a valid JSON-LD object`로 끝났고, 오류 문자열에 그 URL이 있었다. 같은 문서를 인스턴스가 `/contexts/hatto.jsonld`로 제공하고, ActivityStreams 컨텍스트는 Fedify에 이미 있는 로더에 맡기자 `fromJsonLd`가 성공했고 `hatto:rev`는 1이었다. 인라인 컨텍스트는 원격 조회가 없어서 위의 성공 경로들이 그 방식을 썼다.

같은 Activity를 다시 보내는 동작과, rev가 역순으로 오는 동작은 갈린다. rev 1을 같은 Activity id로 두 번 보내고, 이어서 다른 Activity id로 같은 rev를 한 번 더 보냈다. 인박스는 세 번 모두 202였다. 리스너가 본 rev 목록은 `[1, 1]`이다. 이 숫자는 활동 id를 자르지 않고, object URI를 GET한 본문의 `hatto:rev`다. 같은 id의 두 번째 POST는 리스너까지 오지 않았다. 다른 id의 재전송은 리스너에 도착했고, 앱의 `(guid, rev)` 환원기는 적용 1, 중복 1, head 1이었다. Fedify의 짧은 중복 제거는 Activity id에 기대고, 같은 rev를 다른 id로 다시 보내면 앱이 막아야 한다. rev 3을 보낸 다음 rev 1을 보내자 도착 순서는 `[3, 1]`이었고 head는 3에 남았으며, 늦은 rev 1은 저장만 되고 head를 뒤로 밀지 않았다(`olderKept: 1`, 저장된 rev `[1, 3]`). `orderingKey`는 guid로 넘겼지만 `immediate: true`라 큐가 없었고, 이 실행은 보낸 순서 그대로 도착했다. 큐가 역순을 막아 주는지는 재지 않았다.

비공개 덱은 서명 없는 GET이 404였다. 허용 목록에 없는 alice가 자기 키로 서명한 GET도 404였다. 허용된 bob의 서명 GET은 200이었고, 디스패처가 본 서명 주체는 bob의 액터 id였다. 응답의 `hatto:rev`는 1, `hatto:guid`는 `private-deck`이었고, Link의 href는 정적 파일 서버의 서명 URL이었다. 그 URL은 200과 함께 다이제스트가 맞았다. 서명 URL의 수명은 1500ms였고, 그 시간에 250ms를 더 기다린 같은 URL은 404였다. 공개 객체와 달리 비공개 응답에는 만료 없는 CDN 경로를 넣지 않았다.

### Fork·MR

Fork와 Merge Request도 같은 두 인스턴스와 같은 정적 파일 서버로 주고받았다. 활동에는 표준 필드와 URI만 넣었다. 포크가 어느 rev에서 갈라졌는지는 덱 원문 JSON의 `origin`에 두었고, Create의 `origin`에는 같은 rev URI를 라우팅용으로 한 번 더 실었다. 디스패처는 `fromJsonLd`가 돌려준 객체를 `clone`하지 않고 반환한다. 그 원문을 서명 없이 GET한 본문은 733바이트였고, 넣어 둔 JSON을 `JSON.stringify`한 결과와 바이트가 같았다. Alice가 서명한 GET도 그 733바이트와 같았다. 스키마 검사 오류는 0개였다. 검사한 항목은 type에 `hatto:Deck`과 `Object`가 같이 있는지, id, `origin`이 원본 `/decks/fork-source/revs/4`인지, `hatto:rev: 1`, `hatto:guid: "fork-copy"`, Link의 href·mediaType·digestMultibase다. 스냅샷 GET은 200, 본문 15바이트였고 다이제스트가 맞았다.

Create의 object를 포크 rev URI만 넣고 `context`에 원본 덱 URI를 넣으면 인박스는 202였고, 리스너가 읽은 `origin`은 원본 rev URI, `context`는 원본 덱 URI였다. `context`를 빼면 인박스도 202였고 `origin`은 같은 rev URI로 남았으며 `context`는 null이었다. 두 활동의 `hatto:` 키는 없었다. object를 객체로 임베드한 Create도 인박스는 202였고 활동의 `origin`과 `context`는 남았다. 임베드된 객체의 키는 `id`, `type`, `attributedTo`, `name`, `url`뿐이었다. `hatto:` 키는 없었고, 원문에 있던 `origin`도 임베드 안에서는 null이었다. `url`의 `digestMultibase`도 없었다. 포크 원본은 임베드된 객체가 아니라 URI 뒤의 원문이 가지고 있다.

같은 `origin`과 `context`를 `hatto:origin`, `hatto:context`로도 넣어 compact하면 그 두 키는 없어지고 표준 필드만 남는다. 그 Create의 인박스도 202였고, 와이어의 활동에 `hatto:` 키는 없었다.

Merge Request는 `Offer`다. id에는 포크 guid `fork-copy`, rev `1`, target의 host와 덱 guid, 제출 순번이 들어 간다. 순번 1과 순번 2의 id는 달랐다. object는 포크 rev URI, target은 원본 덱 URI, `summary`는 `포크를 머지해 주세요`, `content`는 `fork-copy의 rev 1을 원본에 반영하고 싶습니다`다. compact와 와이어와 Alice의 리스너가 그 네 값을 그대로 봤고 인박스는 202였다. object의 host와 actor의 host는 같았고, 공개 덱이라 읽기 권한 검사는 통과했다.

Alice의 `Accept`는 object에 그 Offer id만 넣었다. 하나는 `result`에 Alice가 만든 Article URI `/activities/merges/fork-copy/revs/1/n/1`을 넣었고, 다른 하나는 `result`에 병합 뒤 rev URI `/decks/fork-source/revs/5`를 넣었다. 둘 다 compact와 와이어와 Bob의 리스너에 `result`가 남았고 인박스는 202였다. Bob이 target 덱을 GET하자 200이었고 `attributedTo`는 Alice의 액터 id라, Accept를 보낸 actor가 소유자라는 검사는 통과했다. `Reject`의 `content`는 `범위가 원본과 다릅니다`였고, compact와 리스너에 그 문자열이 남았으며 object는 거절한 Offer의 id, 인박스는 202였다. 이 실험에서 만든 활동 id 21개를 GET하면 모두 200이었고, 응답의 id는 요청한 URI와 같았다. 21개 안에는 Create, Offer, Accept, Reject, 병합 Article, 병합 rev가 들어 있다.

수신 검사는 인박스가 받은 뒤의 앱 판단이다. object host가 actor host와 다른 Offer도 인박스는 202였고, 앱의 host 검사는 실패했다. 그 Offer의 읽기 검사는 공개 덱이라 통과했다. target이 비공개이고 Bob이 읽기 허용 목록에 있으면 읽기 검사는 통과했고, Bob의 서명 GET은 200이었다. 허용 목록에 없으면 읽기 검사는 실패했고, 서명 없는 GET과 Bob의 서명 GET은 둘 다 404였다. Bob이 자기 인박스에 넣은 Accept는 object가 Alice 덱을 향한 Offer였고, 소유자 검사는 실패했다. 그 Accept의 인박스도 202였다.

순서는 활동 id의 숫자를 쓰지 않았다. 활동 id는 `/revs/9`와 `/revs/8`인데 object가 가리키는 원문의 `hatto:rev`는 2와 1이었다. 9를 먼저 보내고 8을 나중에 보내면 리스너가 읽은 `hatto:rev`는 `[2, 1]`이고 head는 2, 늦은 1은 `olderKept: 1`로 남았다. 인박스는 둘 다 202였다. id만 잘랐으면 `[9, 8]`이 되었을 값이고, 환원기는 그 숫자를 쓰지 않았다.

같은 Offer id를 두 번 보내면 인박스는 둘 다 202였고 리스너는 한 번이었다. Fedify가 그 id에 저장한 값은 TTL을 시간 단위로 반올림한 `PT24H`였다. 벽시계로 24시간을 기다리지는 않았다. 기다린 시간은 0ms다. 수신 쪽 KV의 그 키만 가상 시계로 옮겼다. 시계는 `2026-11-12T11:39:43.243Z`에서 `2026-11-13T11:39:43.243Z`로 24시간 갔고, 키는 아직 살아 있었으며 같은 Offer를 다시 보내도 리스너는 1에 머물렀다. 한 시간을 더 옮겨 `2026-11-13T12:39:43.243Z`가 되자 키는 없어졌고, 같은 Offer의 인박스는 다시 202, 리스너는 2가 되었다. 앱의 중복 키는 Offer id다. 그때 적용 1, 중복 1이었다. 순번만 2로 바꾼 재제출은 id가 달랐고 리스너가 한 번 더 불렸으며, 적용 2, 중복 1이었다. Accept를 Offer보다 먼저 Alice의 인박스에 넣으면 리스너 순서는 `accept`, `offer`였고 둘 다 202였다. 일찍 온 Accept를 붙잡아 두는 큐는 만들지 않았다. `orderingKey`는 넘겼지만 `immediate: true`라, 큐가 순서를 되돌리는지는 재지 않았다.


