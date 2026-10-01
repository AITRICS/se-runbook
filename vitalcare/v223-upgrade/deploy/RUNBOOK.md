# VitalCare 2.2.3 업그레이드

Ubuntu 22.04 / 24.04 병원 서버에서 쓰는 절차다. 기준 템플릿은 `vc-deploy` 의 `upgrade-example-2.2.3` 이다.

```bash
cd vitalcare/v223-upgrade
./pre.sh
./run.sh
```

`./run.sh` 는 tmux 세션 `v223-upgrade` 를 만들고 그 안에서 동작한다. 스크립트가 끝나면 그 세션도 종료된다.

각 스크립트는 실행 전에 시뮬레이션을 보여 준다. 처음 보는 사람은 그 화면으로 순서를 익힌 뒤 `y` 로 실제 작업을 시작한다.

## pre.sh

서버를 변경하지 않는다.

- CPU / RAM / Disk
- 실행 중인 docker compose 프로젝트
- 외부망이 되면 ECR 로그인, ECR 통신, `vc-deploy` git 접근
- 외부망이 안 되면 2.2.3 이미지, CloudBeaver 이미지, 로컬 최신 vc-script, `/home/aitrics/vc-deploy-v223`, NTP

FAIL 이 있으면 종료 코드 1 이다.

## run.sh

```bash
./run.sh initiate
./run.sh script
./run.sh fix-defect
```

인자가 없으면 메뉴에서 고른다.

작업 디렉터리는 `/home/aitrics/vc-deploy-v223/<병원폴더>` 다. compose 가 `../mysql`, `../vitalcare` 를 include 하므로 병원 폴더는 이 저장소 안에 둔다.

### initiate

1. `vc-deploy` 가 없으면 clone 하고, `upgrade-example-2.2.3` 을 병원 폴더로 복사한다.
2. 환경변수를 하나씩 묻는다. 기본값은 괄호로 보여 준다.
   - `.env` 의 `VC_SYNC_IMAGE_TAG` 기본값은 `vc-v2.2.3-latest`
   - `envs/db-encrypt.env` 의 `DB_ENCRYPTION_KEY`, `DB_ENCRYPTION_KEY_HASH` 는 기본값을 보여 주지 않는다.
   - api 이면 `API_BASE_URL`, view 이면 `VCSYNC_EMR_*`
3. `restore-sync`, `restore-observer` 주석을 해제한다.
4. sync 와 observer 를 제외한 컨테이너를 순서대로 올린다.

### script

observer live (`observe run`), sync live (`sync`), 그다음 로컬에서 가장 최근 vc-script 이미지를 실행한다. MySQL 호스트 포트는 `3322` 다.

### fix-defect

이전에 돌린 기록이 `state/<병원>.fix` 에 있으면 먼저 보여 주고, 그대로 돌릴지 묻는다.

- truncate 가 필요하면 `sql/truncate.sql` 을 복사 구간으로 출력한다. 스크립트는 SQL 을 실행하지 않는다.
- restore 를 돌리면 기간을 묻고, `docker compose run` 으로 compose 명령을 override 해서 띄운다. 쓴 기간은 다음 기본값으로 남긴다.
- sync / observer 를 live 로 띄우지 않으면 거기서 끝난다.
