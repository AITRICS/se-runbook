# CARED v2.1.5 배포 자동화

SE가 병원 서버에서 하던 배포를 `deploy.sh` 가 실행한다.

```bash
cd se-runbook/cared
./deploy.sh pre    # 사전점검
./deploy.sh run    # 실 배포
./deploy.sh post   # 사후점검
```

순서를 건너뛸 수 없다. `pre` 가 통과해야 `run`, 해당 병원 `run` 이 끝까지 끝나야 `post`.
각 단계에서 실행 / 미리보기를 고른다. 실제 완료만 `PRE_DONE` / `RUN_DONE` / `POST_DONE` 에 저장한다. 미리보기는 상태를 쓰지 않고, 끝에 다음 단계로 가려면 이 단계를 완료해야 한다는 안내만 한다. (작업자 판단에 따라 pass 가능)

## pre — 사전점검

- `/` 와 `/aitrics-vc` 마운트 확인
- CPU 사용량(%), RAM 사용량
- 현재 실행 중인 docker compose 프로젝트만 표시
- `.env` / `db-encrypt.env` / `sync.env` 설정 완료 안내
- 도커 이미지 — 서버에 이미 로드 / AWS 다운로드. 로드면 이미지 존재 확인, AWS면 통신만 확인 (로그인은 따로)

## run — 실 배포

메뉴에서 고른다.

1. 배포 실행 / 미리보기 / 종료
2. 영문 병원 이름
3. 처음부터 / 중간부터 재개. 이전에 실패했으면 그 단계에 `← 실패` 표시

`run` 은 도커 이미지가 이미 준비된 것을 전제로 한다. pull 하지 않는다.

작업 경로는 `{cared-deploy 절대경로}/{병원}-v215` 이다.

실제 배포가 실패하면 `state/{병원}` 에 실패 단계를 저장한다. 다시 실행하면 재개 메뉴에 표시된다. 끝까지 성공하면 지운다. 미리보기는 저장하지 않는다. 실패해도 `docker compose down` 하지 않고 `{병원}-v215` 상태만 남긴다. 기존 vc-deploy 는 건드리지 않는다.

미리보기는 실제 배포와 같은 함수를 타고, 스크립트가 찍는 `[INFO]` / `==>` 문구는 성공 경로 그대로 보여 준다. git / docker / chmod 만 실행하지 않는다. docker·컨테이너가 직접 쏟는 로그는 실행을 안 해서 안 나온다.

저장된 설정을 쓰려면:

```bash
cp config/example.env config/wonju.env
# 값 채운 뒤 ./deploy.sh run 하면 병원 이름에 맞는 파일을 읽는다
```

### 실행 순서

1. `cared-deploy` clone/재사용
2. `example-2.1.5` → `{병원}-v215` 복사
3. `CONFIG_DIR` / `HOST_NAME` 만 맞추고, env 값은 이미 채워 둔 파일을 사용
4. 기존 vc-deploy 와 컨테이너/포트 충돌 검사. 겹치면 중단
5. mysql healthy
6. sync-migration exit 0
7. backend-migration exit 0
8. backend (`db-encrypt.env` 깨지면 중단)
9. frontend / admin
10. observer 한 사이클 (`observer run end`, 5 / 15 / 25분)
11. sync 한 사이클 (`sync end :`, 10 / 20 / 30분)
12. `$VOLUME_DIR/logs` chmod 777
13. scoring 3종, scoring-manager 한 사이클 (`Finish recording scores`)
14. `vc-script:v2.2.2` 검수. 전체 결과 후 **FAILED만 따로 출력**

기존 vc-deploy 와 분리하는 방법:

- 작업 폴더 / compose project: `{병원}-v215`
- 컨테이너 이름: `*-cared`
- 포트: 1080, 13000, 14000, 13306, 37017
- `VOLUME_DIR` 은 example-2.1.5 `.env` 값을 그대로 둠

## post — 사후점검

병원 이름을 받은 뒤:

- pre 와 같은 마운트 / CPU·RAM / compose 프로젝트 수
- `{병원}-v215` 컨테이너가 떠 있는지
