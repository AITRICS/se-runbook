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

작업 디렉터리와 compose project 이름은 `/home/aitrics/vc-deploy-v223/<병원이름>-v223` 이다. 입력한 병원 이름 그대로 쓰면 기존 compose 프로젝트와 겹친다. compose 가 `../mysql`, `../vitalcare` 를 include 하므로 병원 폴더는 이 저장소 안에 둔다.

### initiate

1. `vc-deploy` 가 없으면 clone 하고, `upgrade-example-2.2.3` 을 병원 폴더로 복사한다.
2. 병원 폴더에서 `sudo bash ./init-deploy-settings.sh` 로 볼륨 디렉터리를 만든다.
3. `create-certificate-file.sh`, `download-bat-file.sh` 를 순서대로 실행한다.
4. 환경변수를 하나씩 묻는다. 기본값은 괄호로 보여 준다.
   - `.env` 의 `VC_SYNC_IMAGE_TAG` 기본값은 `vc-v2.2.3-latest`
   - `envs/db-encrypt.env` 의 `DB_ENCRYPTION_KEY`, `DB_ENCRYPTION_KEY_HASH` 는 다른 환경변수와 같이 입력한다. 파일에 값이 있으면 기본값으로 보여 준다.
   - api 이면 `API_BASE_URL`, view 이면 `VCSYNC_EMR_*`
   - `envs/sync.env` 의 `VCSYNC_SYNC_DNR` 은 `true` 또는 `false` 로 묻는다.
5. `restore-sync`, `restore-observer` 주석을 해제한다.
6. sync 와 observer 를 제외하고 순서대로 올린다. mysql 은 healthy 가 된 뒤에 다음으로 넘어간다.
   `mysql`, `sync-migration`, `backend-migration`, `rabbitmq`, `backend`, `frontend`, `admin`, `mongodb`, `vcsm-kotlin`, `dlq-manager`, `scoring-service`, `screening-service`

### script

observer live (`observe run`), sync live (`sync`), 그다음 로컬에서 가장 최근 vc-script 이미지를 실행한다. MySQL 호스트 포트는 `3322` 다.

### fix-defect

이전에 돌린 기록이 `state/<병원>.fix` 에 있으면 먼저 보여 주고, 그대로 돌릴지 묻는다.

- truncate 가 필요하면 `sql/truncate.sql` 을 복사 구간으로 출력한다. 스크립트는 SQL 을 실행하지 않는다.
- restore 를 돌리면 기간을 묻고, `docker compose run` 으로 compose 명령을 override 해서 띄운다. 쓴 기간은 다음 기본값으로 남긴다.
- sync / observer 를 live 로 띄우지 않으면 거기서 끝난다.
