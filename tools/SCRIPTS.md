# Reusing-unibench 스크립트 문서

`tools/` 하위 스크립트와 설정 파일의 역할 및 사용법.

변수 레퍼런스는 여기 없다. captainrc가 읽는 모든 노브는
[`captainrc.examples/README.md`](captainrc.examples/README.md)에 있고, 이 문서는
**스크립트가 무엇을 하는가**만 다룬다.

---

## 목차

1. [전체 구조 개요](#전체-구조-개요)
2. [실험 워크플로](#실험-워크플로)
3. [설정 파일](#설정-파일)
4. [캠페인 실행](#캠페인-실행)
5. [아카이빙 · 커버리지 측정](#아카이빙--커버리지-측정)
6. [컨테이너 내부 엔트리포인트](#컨테이너-내부-엔트리포인트)
7. [시드 코퍼스 도구](#시드-코퍼스-도구)
8. [시각화](#시각화)
9. [분석 디렉토리](#분석-디렉토리)
10. [유틸리티](#유틸리티)

---

## 전체 구조 개요

```
tools/
├── captainrc.examples/        # 커밋되는 설정 템플릿 (live captainrc는 gitignore)
│   ├── README.md              #   용도별 선택 가이드 + 전체 노브 레퍼런스
│   ├── baseline               #   고정 길이 캠페인
│   ├── saturation_gen         #   포화 코퍼스 생성
│   ├── saturation_experiment  #   포화 코퍼스에서 출발하는 실험
│   └── reusing                #   reusing 팔 (TAINT_DIR 필수)
│
├── run.sh                     # 캠페인 실행 진입점
├── build.sh                   # Docker 이미지 빌드
├── start.sh                   # 단일 캠페인 컨테이너 실행
├── common.sh                  # 공통 함수
│
├── archive_campaigns.sh       # 캠페인 구동 드라이버 (큐 스냅샷 + 종료 제어)
├── archive_queue.sh           # 큐 증분 아카이브 (iter_NNNN.tar.gz)
├── make_base_archive.sh       # iter_0000 베이스 스냅샷 생성
├── measure_coverage.sh        # 오프라인 커버리지 측정 (캠페인 종료 후)
├── measure_coverage_old.sh    # 구 라이브 측정 방식 (보존용)
├── watch_target_done.sh       # 타겟 단위로 아카이빙 끝나면 측정 자동 시작
│
├── merge_saturated_seed.sh              # trial 0-4 큐 병합 → 시드
├── merge_saturated_seed_cross_fuzzer.sh # 모든 퍼저 × 모든 id 큐 병합
├── trim_to_day5.sh                      # 큐를 day5(iter_0480) 시점으로 자르고 재병합
├── run_seed_coverage.sh                 # 시드 디렉토리 전체의 브랜치 커버리지 출력
│
├── plot_coverage.py           # 타겟별 브랜치 커버리지 시계열
├── diff_coverage.py           # 베이스라인 대비 차이 시계열
├── plot_area_bars.py          # 차이 면적(net) 요약 막대
├── plot_rotation_coverage.py  # 로테이션 실험 일자별 CSV 이어 붙이기
├── boxplot.py / boxplot_ratio.py / km_curve.py
│
├── coverage_analysis/         # 입력 단위 커버리지 분석 (아래 참조)
├── pattern_analysis/          # dtaint 패턴 분석
├── measure_memory.sh          # 컨테이너 메모리 사용량
└── volume/                    # 컨테이너에 마운트되는 볼륨
    ├── targets.conf           #   타겟별 인수/시드/소스 경로
    ├── entrypoint.sh          #   퍼저 컨테이너 공통 엔트리포인트
    ├── <fuzzer>/run.sh        #   퍼저별 실행 스크립트
    ├── seeds/                 #   타겟별 초기 시드
    └── coverage/              #   커버리지 컨테이너 엔트리포인트들
```

Docker 이미지: `unifuzz/unibench:<fuzzer>`, `unifuzz/unibench:coverage`

### 현재 퍼저 팔

`tools/volume/<name>/run.sh`가 있는 것이 실행 가능한 팔이다.

| 이름 | 설명 |
|---|---|
| `aflplusplus` | AFL++ 베이스라인 |
| `aflplusplus-autoextras` | 위와 **같은 이미지**, 런타임 환경변수만 다름 |
| `aflplusplus-cmplog` | CmpLog 활성 AFL++ |
| `aflplusplus-reusing` | AFL++ fork + `-r` reusing 스테이지. `TAINT_DIR` 필수 |
| `forkserver_libafl` | LibAFL forkserver 베이스라인 |
| `forkserver_libafl_reusing` | 위 + reusing 스테이지. `TAINT_DIR` 필수 |
| `forkserver_storfuzz` | StorFuzz 비교군 |
| `reusing-scanner` | **퍼저 아님.** 코퍼스를 한 번 스캔해 taint 캐시 생성 |

`angora` 계열 팔은 더 이상 없다. 과거 설정은 git 히스토리에 남아 있다.

---

## 실험 워크플로

커버리지를 **퍼징 중에** 재지 않는다. 캠페인 동안에는 큐 스냅샷만 떠 두고,
끝난 뒤 놀고 있는 코어에서 재생(replay)한다. 퍼저가 고정된 코어를 쓰는데
lcov/genhtml이 같은 머신에서 돌면 측정이 실험을 오염시키기 때문이다.

```
① 스캔 (reusing 팔만)
   FUZZER=reusing-scanner ./build.sh
   run.sh로 1회 실행 → value_pool.dict / unsolved_condition / *.dtaint
                                    ↓ 이 디렉토리가 <target>_TAINT_DIR

② 캠페인
   screen -dmS archiver ./archive_campaigns.sh WORKDIR 15 96   ← 먼저 띄운다
   ./run.sh captainrc_myrun
      · archive_queue.sh가 캠페인마다 하나씩 붙어 INTERVAL마다 큐 증분 스냅샷
      · MAX_ITERATIONS 도달 → archive_done → 드라이버가 컨테이너에 SIGINT
      · 캠페인 길이 = INTERVAL × MAX_ITERATIONS 분

③ 오프라인 측정
   ./measure_coverage.sh WORKDIR 15 [-t 타겟] [-f 퍼저] [-p 병렬수] [-c 코어목록]
      → coverage/<fuzzer>/<target>/<id>/coverage_over_time.csv

④ 시각화
   ./plot_coverage.py WORKDIR --interval 15
```

`TIMEOUT`을 captainrc에 박으면 ②의 드라이버 없이도 캠페인은 끝나지만, 큐
스냅샷이 없으므로 시계열 커버리지는 못 만든다. 최종 누적 커버리지만 필요하면
`coverage_analysis/measure_aggregate_coverage.sh`를 쓴다.

---

## 설정 파일

### captainrc

`run.sh`가 `set -a`로 소싱하는 Bash 파일. **live captainrc는 gitignore 대상이다**
(`.gitignore`의 `*captainrc*`). 머신별 절대 경로와 코어 할당이 박혀 있어 다른
서버로 넘어가는 순간 썩기 때문이다.

커밋되는 것은 `captainrc.examples/`의 템플릿 4종뿐이다.

```bash
cp captainrc.examples/saturation_experiment captainrc_myrun
vi captainrc_myrun          # /path/to/... 자리표시자를 전부 채운다
./run.sh captainrc_myrun
```

| 템플릿 | 용도 |
|---|---|
| `baseline` | 고정 길이 일반 캠페인 |
| `saturation_gen` | 포화 코퍼스 생성 (`SATURATION_GEN=1`). 마지막 큐가 다음 실험의 시드가 된다 |
| `saturation_experiment` | 포화 코퍼스에서 **출발**하는 실험 (`SATURATION_MODE=1`) |
| `reusing` | reusing 팔. 위와 같고 `TAINT_DIR`이 추가로 필수 |

**변수 전체 목록과 의미는 [`captainrc.examples/README.md`](captainrc.examples/README.md)**에 있다.
과거 서버별 설정은 `git log --all -- tools/captainrc*`로 찾을 수 있다 (2026-10 추적 해제).

---

### volume/targets.conf

타겟의 실행 인수, 시드 디렉토리, 커버리지 소스 경로를 정의한다. 컨테이너 안에서
`/volume/targets.conf`로 마운트되어 퍼저 엔트리포인트와 모든 커버리지
엔트리포인트가 소싱한다.

변수명에서 하이픈(`-`)은 언더스코어(`_`)로 바꾼다 (`gdk-pixbuf-pixdata` →
`gdk_pixbuf_pixdata_args`).

| 변수 패턴 | 설명 |
|---|---|
| `<target>_args` | 실행 인수 배열. `@@`가 입력 파일 경로로 치환된다 |
| `<target>_seed_dir` | 컨테이너 내 `/seeds/` 하위 시드 디렉토리 이름 |
| `<target>_source_dir` | lcov가 `.gcno`/`.gcda`를 찾을 소스 디렉토리 (컨테이너 내 절대 경로) |
| `<target>_stdin_from_file` | `1`이면 입력을 stdin으로 넘긴다. 현재 `sqlite3`만 해당 |

정의된 타겟 (24개):

```
exiv2  tiffsplit  mp3gain  wav2swf  pdftotext  infotocap  mp42aac  flvmeta
objdump  tcpdump  ffmpeg  gdk_pixbuf_pixdata  cflow  nm  sqlite3  lame
jhead  imginfo  jq  mujs  uniq  base64  md5sum  who
```

`@@`가 없는 타겟(`sqlite3`)은 stdin 방식이며, `taint_scan`도 `@@` 부재를 stdin
모드로 해석한다 — 퍼저 쪽 `CommandOpt`와 같은 규칙이다.

---

## 캠페인 실행

### run.sh

캠페인 매트릭스(`FUZZERS × TARGETS × REPEAT`)를 CPU 풀 위에 펼쳐 실행하는 진입점.

```bash
./run.sh [captainrc 경로]      # 생략 시 ./captainrc
```

동작:

```
captainrc 소싱 (set -a: 모든 할당이 export)
    ↓
CPU 풀 결정 (WORKER_POOL, 없으면 lscpu로 전체)
    ↓
WORKDIR 하위 생성: ar/ cache/ log/ poc/ lock/
    ↓
FUZZERS 각각에 대해 build.sh (이미 빌드돼 있으면 캐시 no-op)
    ↓
reusing 팔이 있으면 TAINT_DIR 검증 (없거나 경로가 틀리면 여기서 중단)
    ↓
FUZZER × TARGET × REPEAT:
  - allocate_workers()로 코어 점유 (flock mutex, inotifywait으로 해제 감지)
  - SATURATION_MODE=1이면 make_base_archive.sh로 iter_0000 미리 설치
  - start.sh 실행 (백그라운드)
  - 종료 후 SATURATION_GEN=1이면 최종 큐를 base.tar.gz로 tar
  - cache/<...>/<id> → ar/<...>/<id> 로 이동
```

디렉토리 레이아웃:

```
WORKDIR/
├── ar/<fuzzer>/<target>/<id>/      # 캠페인 종료 후 findings가 이동되는 곳
├── cache/<fuzzer>/<target>/<id>/   # 실행 중 컨테이너의 live 공유 볼륨
├── coverage/<fuzzer>/<target>/<id>/ # archives/, coverage_over_time.csv
├── log/                            # 컨테이너 로그, 빌드 로그
├── poc/                            # 미사용
└── lock/                           # CPU 점유 lock 파일
```

기존 WORKDIR을 재사용하면 **덮어쓰지 않고 이어붙인다** — trial id가 기존 최대값
다음부터 매겨진다.

`TAINT_REQUIRED_FUZZERS`(`aflplusplus-reusing`, `forkserver_libafl_reusing`)는
`<target>_TAINT_DIR`(또는 전역 `TAINT_DIR`) 없이는 실행을 거부한다. 풀 없이 조용히
돌아간 캠페인은 나중에 베이스라인과 구분할 수 없기 때문이다.

---

### build.sh

```bash
FUZZER=<이름> ./build.sh

FUZZER=aflplusplus-reusing ./build.sh
FUZZER=reusing-scanner     ./build.sh
FUZZER=coverage            ./build.sh
```

대부분의 퍼저는 단순히 `docker build -f <fuzzer>/Dockerfile $UNIBENCH/../`를 돈다.
**빌드 컨텍스트가 움브렐라 레포 루트**라서 Dockerfile의 `COPY` 경로에
`Reusing-unibench_build/` 접두사가 붙는다.

세 개는 특수 분기를 탄다.

**해시 기반 증분 빌드 (`aflplusplus-reusing`, `forkserver_libafl_reusing`)**

소스를 두 그룹으로 나눠 따로 해시하고 `<fork>/_build_cache/`에 저장한다. 기준은
하나다 — **이 변경이 타겟 컴파일 방식에 영향을 주는가, 퍼저 바이너리만 바꾸는가.**

| 팔 | 퍼저 전용 (싼 빌드) | 그 외 (전체 재빌드) |
|---|---|---|
| `aflplusplus-reusing` | `src/afl-fuzz*`, `src/afl-main.c`, `include/afl-fuzz.h`, `include/reusing_*` | instrumentation, afl-cc — 베이스 + 19개 타겟, ~20분 |
| `forkserver_libafl_reusing` | `fuzzers/reusing_core/`, `fuzzers/reusing_forkserver_cc/src/main.rs` | `libafl_cc.rs`, `src/lib.rs`, `libafl*/` 전부 |

분류되지 않은 파일은 전체 재빌드 쪽으로 떨어진다 — 조용히 낡은 타겟 이미지를
쥐는 것보다 안전하다. 각 팔의 `-target/` Dockerfile 디렉토리도 toolchain 해시에
포함되므로, 그것만 고쳐도 "변경 없음"으로 빠지지 않는다.

해시는 `git ls-files`로 뽑은 **파일 내용**이다. tar가 아닌 이유는 mtime이 기록돼
갓 클론한 트리가 매번 다른 해시를 내기 때문이고, gitlink는 디렉토리라 걸러낸다
(두 fork 모두 upstream 서브모듈을 품고 있다).

**`reusing-scanner`**

퍼저가 아니라 스캐너다. "퍼저만 바뀐" 경우가 없으므로 해시는 하나뿐이며,
스캐너 레포와 `reusing-scanner-target/` 양쪽을 함께 해시한다.

**`aflplusplus` / `aflplusplus-autoextras`**

같은 이미지다. 차이는 런타임 환경변수뿐이라, 어느 쪽을 빌드하든 나머지 태그를
같이 갱신한다.

환경변수로 fork 위치를 바꿀 수 있다: `AFLPP_REUSING_ROOT`, `LIBAFL_REUSING_ROOT`,
`REUSING_SCANNER_ROOT`. 기본값은 모두 움브렐라 아래 형제 디렉토리다.

---

### start.sh

단일 캠페인을 컨테이너로 띄운다. `run.sh`가 호출하지만 직접 실행해도 된다.

```bash
FUZZER=aflplusplus-reusing TARGET=jq \
SHARED=/path/shared TAINT_DIR=/path/to/scan_out TIMEOUT=24h \
./start.sh
```

| 변수 | 필수 | 설명 |
|---|---|---|
| `FUZZER` | ✓ | 이미지 `unifuzz/unibench:<FUZZER>` |
| `TARGET` | ✓ | 타겟 이름 |
| `SHARED` | ✓ | 컨테이너의 `/unibench_shared`로 마운트될 호스트 디렉토리 |
| `TIMEOUT` | | `timeout(1)` 문법. 없으면 무기한 |
| `SEED` | | `/customized_seed` (ro) |
| `TAINT_DIR` | reusing 팔 | `/taint` (ro). taint 캐시 |
| `DISABLE_TRIM` | | 컨테이너 안에서 `AFL_DISABLE_TRIM` export (AFL++ 팔만) |
| `QUEUE_FILE` | | `/restore/cond_queue.csv` (ro) |
| `FUZZARGS` | | 퍼저 명령줄에 덧붙일 인수 |
| `AFFINITY` | | `--cpuset-cpus` |
| `RUN_SCRIPT` | | `/volume/<fuzzer>/` 안에서 쓸 스크립트 이름 (기본 `run.sh`) |
| `ENTRYPOINT` | | 기본 `/volume/entrypoint.sh` |
| `ROOT_MODE` | | 설정 시 root 실행 (기본은 호스트 UID/GID) |

TTY가 있으면 `docker run -it`(포그라운드), 없으면 `-dt` 후 `docker logs -f`로
스트리밍한다.

`aflplusplus-reusing`은 `-r`이 트리밍을 강제로 끈다. 트리밍이 큐 엔트리를 다시
쓰면 그 `.dtaint`의 모든 오프셋이 엉뚱한 바이트를 가리키게 되기 때문이다.

---

### common.sh

| 함수 | 설명 |
|---|---|
| `echo_time <msg>` | `[YYYY-MM-DD HH:MM] msg` |
| `contains_element <val> <array...>` | 포함되면 0 |
| `get_var_or_default <key...>` | `key1_key2_...` → 없으면 `DEFAULT_key2_...` 순으로 탐색 |

`get_var_or_default aflplusplus-reusing jq FUZZARGS`는
`aflplusplus_reusing_jq_FUZZARGS` → `DEFAULT_jq_FUZZARGS` → `jq_FUZZARGS` 순으로
찾는다. captainrc의 퍼저/타겟별 계층 설정이 이 함수 위에 서 있다.

---

## 아카이빙 · 커버리지 측정

### archive_campaigns.sh

캠페인 구동 드라이버. **커버리지 컨테이너를 띄우지 않는다** — 퍼징 중에는 lcov를
돌리지 않는 것이 이 워크플로의 핵심이다.

```bash
./archive_campaigns.sh WORKDIR INTERVAL MAX_ITERATIONS [--measure]

# 15분 간격 × 96회 = 24시간
./archive_campaigns.sh ../_result 15 96

# 15분 × 480회 = 5일
./archive_campaigns.sh ../_result 15 480
```

| 인수 | 설명 |
|---|---|
| `WORKDIR` | `run.sh`와 같은 작업 디렉토리 |
| `INTERVAL` | 스냅샷 간격 (**분** 단위. `plot_coverage.py`와 통일) |
| `MAX_ITERATIONS` | 스냅샷 횟수. 캠페인 길이 = `INTERVAL × MAX_ITERATIONS` 분 |
| `--measure` | 모든 캠페인이 아카이빙을 마친 뒤 `measure_coverage.sh`까지 자동 실행 (기본은 아카이빙만) |

동작:

- `WORKDIR/cache/`를 폴링(기본 10초)하다 새 캠페인이 보이면 `archive_queue.sh`를
  하나 붙인다. `nice -n 19 ionice -c 3`으로 감싸서 고정 코어의 퍼저와 경쟁하지
  않는다.
- 캠페인이 `MAX_ITERATIONS`에 도달하면 아카이버가 `archive_done`을 쓰고, 드라이버가
  해당 퍼저 컨테이너에 SIGINT를 보낸다. 즉 **캠페인 길이를 결정하는 것이 이
  드라이버**이며, captainrc의 `TIMEOUT`은 이 조합에서 보통 비워 둔다.
- `set -e`를 일부러 쓰지 않는다. 사라지는 캠페인 디렉토리에 대해 docker/ls가 내는
  일시적 비정상 종료 코드가 감시 전체를 죽이면 안 되기 때문이다.

**먼저 띄워라.** 캠페인이 나타날 때까지 idle하므로 미리 떠 있어도 손해가 없지만,
늦게 붙으면 첫 스냅샷 구간이 일그러진다.

```bash
screen -dmS archiver bash -c './archive_campaigns.sh WORKDIR 15 96; exec bash'
./run.sh captainrc_myrun
```

주의: 눈에 보이는 모든 캠페인이 아카이빙을 끝내면 드라이버가 스스로 종료한다.
코어 부족으로 실행이 여러 웨이브로 쪼개지면 다음 웨이브를 위해 다시 띄워야 한다.

---

### archive_queue.sh

큐 디렉토리를 `iter_NNNN.tar.gz`로 스냅샷한다. `archive_campaigns.sh`가
백그라운드로 호출한다.

```bash
./archive_queue.sh CACHE_DIR ARCHIVE_DIR INTERVAL [MAX_ITERATIONS]
```

`INTERVAL`은 여기서는 **초** 단위다 (`archive_campaigns.sh`가 분 → 초로 변환해
넘긴다).

**증분 아카이브다.** 각 `iter_NNNN.tar.gz`에는 직전 이터레이션 이후 새로 발견된
큐 파일만 들어간다. 전체 스냅샷이 아니므로 재생할 때는 누적해서 풀어야 한다
(`volume/coverage/entrypoint.sh`가 그렇게 한다).

왜 매번 전체 readdir을 하는가 — `find -newer` + 워터마크는 동시 수정되는
디렉토리에서 **완전하지 않다**. ext4 htree 디렉토리의 단일 readdir이 살아 있는
엔트리를 건너뛸 수 있고(POSIX가 보장하지 않는다), mtime이 워터마크와 같은 파일은
엄격한 `-newer`에서 제외된다. 워터마크가 전진하면 그 파일들은 영원히 누락된다 —
조용하고 영구적인 손실이다. 그래서 매 이터레이션 전체를 훑고, 이미 아카이브한
basename 목록(`.archived_names` 매니페스트)과 대조해 중복을 거른다. 한 번 놓친
파일은 다음 스캔이 주워 담고(자가 치유), 매니페스트 덕에 재시작도 안전하다.

| 환경변수 | 기본 | 설명 |
|---|---|---|
| `MIN_SLEEP` | 60 | 간격 하한. 아카이버가 퍼저/디스크를 굶기지 않도록 |
| `DRYRUN_WAIT_TIMEOUT` | 0 | `dryrun_finish`를 기다리는 초. 0이면 무한 대기 |
| `ARCHIVE_MODE` | `tar` | `tar`=자족적 tar.gz, `log`=파일명만 `queue.log`에 기록 |
| `BASE_ARCHIVE` | — | 미리 만들어둔 베이스를 `iter_0000.tar.gz`로 설치 |

동작 순서:

1. `findings/queue/` 또는 `findings/default/queue/` 탐색 대기
   (AFL++ 계열은 후자, LibAFL forkserver 팔은 전자)
2. `queue/signal/dryrun_finish` 대기 — 시드 임포트 완료 신호
3. `INTERVAL`마다 전체 스캔 → 신규 파일만 `iter_NNNN.tar.gz`
4. `MAX_ITERATIONS` 도달 시 `archive_done` 생성

`ARCHIVE_DIR`당 아카이버는 하나다(`.archiver.lock` flock). 드라이버 재시작 시
두 개가 경쟁해 매니페스트를 깨뜨리는 것을 막는다.

**포화 모드**: `iter_0000.tar.gz`가 이미 있거나 `.skip_preloaded` 플래그가 있으면
포화 모드로 판단하고, `dryrun_finish` 시점에 존재하던 시드를 베이스로 표시해
델타에서 제외한다. 그러지 않으면 첫 스냅샷이 10만 개짜리 dry-run 큐를 통째로
삼킨다. 베이스/발견 경계는 `dryrun_finish` **신호 파일의 mtime**이며,
`.base_marked` 센티넬로 한 번만 수행한다 — 매니페스트가 없는 재시작이 살아 있는
큐를 다시 베이스로 찍는 사고를 막는다.

---

### make_base_archive.sh

`iter_0000` 베이스 스냅샷을 만든다. 내부 경로를 `findings/queue/id:*`로 맞춰
오프라인 커버리지(`find "*/queue/id:*"`)가 그대로 재생할 수 있게 한다.

```bash
./make_base_archive.sh SRC OUT.tar.gz
```

`SRC`는 자동 판별하며, 싼 것부터:

1. **`.tar.gz` 파일** — 이미 만들어진 베이스(`SATURATION_GEN` 산출물 등). 복사만.
2. **`id:*`가 든 디렉토리** — 퍼저의 `findings/queue`. 심볼릭 링크 + `tar -h`로
   바로 묶는다 (mtime 보존, 파일별 cp 없음).
3. **`iter_*.tar.gz`가 든 디렉토리** — 커버리지 아카이브 시리즈. 전부 누적 전개 후
   합집합을 다시 묶는다. 가장 비싸다.

멱등(OUT이 있으면 건너뜀)이고 동시 실행 안전(mktemp + atomic mv)이다.
`run.sh`가 `SATURATION_MODE=1`에서 직접 호출한다.

---

### measure_coverage.sh

**캠페인이 끝난 뒤** 아카이브를 재생해 커버리지 시계열을 뽑는다. 퍼저가 없으니
비어 있는 코어를 마음껏 병렬로 쓴다.

```bash
./measure_coverage.sh WORKDIR INTERVAL [-t 타겟] [-f 퍼저] [-r 반복] [-p 병렬] [-c 코어]

# 전체
./measure_coverage.sh ../_result 15

# nm, objdump만 / 코어 0-9에 핀 / 컨테이너 10개
./measure_coverage.sh ../_result 15 -t nm,objdump -c 0-9 -p 10
```

| 인수 | 설명 |
|---|---|
| `WORKDIR` | 캠페인에 쓴 작업 디렉토리 (`coverage/`가 있어야 한다) |
| `INTERVAL` | 스냅샷당 **분**. `archive_campaigns.sh`에 준 값과 같아야 시간축이 맞는다 |
| `-t` | 타겟 필터, 쉼표 구분. 기본 전체 |
| `-f` | 퍼저 필터, 쉼표 구분. `-t`와 AND |
| `-r` | 스냅샷당 입력 재생 횟수 (기본 1). 비결정적 커버리지를 합집합으로 모은다 |
| `-p` | 동시 컨테이너 수 (기본 `nproc`, `-c` 있으면 그 코어 수) |
| `-c` | `--cpuset-cpus` 스펙(`0-9`, `0,2,4-7`). 컨테이너당 코어 1개를 라운드로빈 — 재생이 싱글스레드라 그게 최적 |

환경변수(해당 옵션이 없을 때만 쓰이는 폴백): `COVERAGE_IMAGE`, `COV_TIMEOUT`(기본 5),
`COV_RUNS`, `PARALLEL`, `CAPTURE_STRIDE`, `FINAL_HTML`.

출력:

```
WORKDIR/coverage/<fuzzer>/<target>/<id>/
├── archives/iter_NNNN.tar.gz
├── coverage_over_time.csv    # 스냅샷별 branch/line/function 시계열
├── coverage.info             # 최종 lcov 데이터
└── html/                     # FINAL_HTML=1일 때만
```

`measure_coverage_old.sh`는 캠페인과 **동시에** 돌던 구 방식이다. 지금 워크플로에는
쓰지 않으며 비교/재현용으로 남아 있다.

---

### watch_target_done.sh

`archive_done` 마커를 지켜보다가, **한 타겟의 모든 캠페인**(모든 퍼저 × 모든 repeat
id)이 아카이빙을 마치는 즉시 그 타겟만 측정을 시작한다. 워크디렉토리 전체가
끝나기를 기다리지 않는다.

```bash
./watch_target_done.sh WORKDIR INTERVAL FUZZERS TARGETS REPEAT [POLL_SECONDS] [ID_START]

./watch_target_done.sh ../_result 15 aflplusplus,aflplusplus-reusing jq,nm,cflow 5
```

dry-run 길이가 타겟마다 달라 `archive_done`이 서로 다른 시각에 떨어질 때 유용하다.
`ID_START`는 이전 실패한 런이 낮은 id를 이미 소비해 캠페인이 `0..REPEAT-1`에
안 떨어진 경우에 쓴다. 순수 폴링이라 캠페인 내내 띄워 둬도 된다.

---

## 컨테이너 내부 엔트리포인트

호스트 스크립트가 `--entrypoint`으로 지정해 실행한다. 직접 호출하지 않는다.

### volume/entrypoint.sh (퍼저 컨테이너)

모든 퍼저 컨테이너의 기본 엔트리포인트.

1. `FUZZER`, `TARGET` 검증
2. `/volume/targets.conf` 소싱 → `<target>_args`를 공백 보존하며 문자열로 포장
3. `/volume/$FUZZER/$RUN_SCRIPT` 실행 (`RUN_SCRIPT` 기본값 `run.sh`)
4. `TIMEOUT`이 있으면 `timeout --signal=INT`로 감싸고, 출력은 `multilog`로
   회전시킨다 (`LOGSIZE`, 기본 1 MiB)

퍼저별 실제 명령줄은 `volume/<fuzzer>/run.sh`에 있다. reusing 팔의 run.sh는
`TAINT_DIR`이 비어 있으면 **`-r`을 빼고 돌리는 대신 에러로 죽는다** — 풀 없이
돌아간 캠페인이 베이스라인과 구분되지 않기 때문이다.

### volume/coverage/entrypoint.sh (오프라인 측정)

`measure_coverage.sh`가 띄운다.

| 마운트 | 내용 |
|---|---|
| `/archives` (ro) | `iter_NNNN.tar.gz` |
| `/coverage_out` | 결과 출력 |
| `/volume` | `tools/volume/` |

| 환경변수 | 기본 | 설명 |
|---|---|---|
| `TARGET` | (필수) | 타겟 이름 |
| `MEASUREMENT_INTERVAL` | 900 | 스냅샷당 초. CSV 시간축 계산에만 쓰인다 |
| `COV_TIMEOUT` | 5 | 입력당 재생 타임아웃 |
| `COV_RUNS` | 8 | 입력당 재생 횟수 |
| `CAPTURE_STRIDE` | 1 | N번째 스냅샷마다 캡처 (마지막은 항상) |
| `FINAL_HTML` | 0 | 1이면 마지막에 genhtml 1회 |

스냅샷을 **누적** 전개해 재생하고, 매 구간 `lcov --summary`로 요약만 뽑는다
(구 방식의 매 구간 genhtml 대비 훨씬 싸다). `COV_RUNS`회 반복 재생하는 이유는
gcov가 같은 `.gcda`에 히트를 누적하기 때문이다 — 반복하면 분기 집합의 합집합이
남아, 순서·초기화·타이밍에 의존하는 분기를 한 번 실행으로 놓치는 것을 복구한다.

출력: `/coverage_out/coverage_over_time.csv`.

`entrypoint_old.sh`는 라이브 측정 시절 버전이다.

### volume/coverage/entrypoint_single_coverage.sh

입력 파일 하나의 커버리지. `coverage_analysis/single_input_coverage.sh`가 띄운다.
마운트는 `/input`(ro), `/report`, `/volume`. gcov 리셋 → 1회 실행 →
`lcov --capture` → `genhtml`.

### volume/coverage/entrypoint_find_coverage_increasing_inputs.sh

큐 파일을 id 순으로 하나씩 넣어 가며 **어떤 입력이 새 브랜치를 열었는지** 추적한다.
`/findings` 마운트, `TARGET`과 `SEED_COUNT`(초기 시드 개수) 필요. 앞 `SEED_COUNT`개를
한꺼번에 돌려 베이스라인을 잡고, 그다음부터 하나씩 비교한다.
결과는 `/findings/coverage_analysis.txt`:

```
<시드 브랜치 수>
<새 브랜치를 연 입력 id>
  <file>:<line>:<block>:<branch>
<다음 입력 id>
```

### volume/coverage/entrypoint_measure_aggregate_coverage.sh

여러 trial의 큐를 한꺼번에 돌려 누적 커버리지를 낸다. `/target_dir`에
`WORKDIR/ar/<fuzzer>/<target>/`를 마운트한다. 결과는
`/target_dir/coverage_all_trials.txt`:

```
branch_hit:   4473
branch_total: 57470
line_hit:     8921
line_total:   23401
total_inputs: 15234
```

### volume/coverage/entrypoint_run_seed_coverage.sh

시드 디렉토리 하나를 전부 실행해 브랜치 커버리지를 찍는다.
`run_seed_coverage.sh`가 띄운다.

---

## 시드 코퍼스 도구

### merge_saturated_seed.sh

한 (퍼저, 타겟)의 trial 0-4 큐를 SHA-256 해시로 중복 제거해 하나의 시드
코퍼스로 합친다.

```bash
./merge_saturated_seed.sh /path/to/ar/<fuzzer>/<target>
# 입력: <dir>/{0,1,2,3,4}/findings/queue/id:*
# 출력: <dir>/saturated_seed/
```

### merge_saturated_seed_cross_fuzzer.sh

`<base_dir>/ar/*/<target>` 아래 **모든 퍼저 × 모든 id**의 큐를 타겟별로 합친다.
위와 달리 경로를 일일이 주지 않고 WORKDIR 하나만 준다.

```bash
./merge_saturated_seed_cross_fuzzer.sh <base_dir> [-t 타겟,타겟...]

./merge_saturated_seed_cross_fuzzer.sh .../saturation_parallel/day2 -t exiv2,imginfo
```

`-t`는 캠페인이 아직 도는 중이라 일부 타겟만 전 퍼저에서 끝났을 때 쓴다.

### trim_to_day5.sh

각 trial의 큐를 day-5(`iter_0480`) 시점 상태로 자른 뒤 시드를 다시 병합한다.
더 긴 런에서 5일치만 떼어 비교할 때 쓴다.

```bash
./trim_to_day5.sh <saturation_dir>
```

### run_seed_coverage.sh

시드 디렉토리의 입력을 전부 한 번씩 실행하고 브랜치 커버리지를 stdout에 찍는다.
병합한 코퍼스가 기대한 커버리지를 갖는지 확인할 때.

```bash
./run_seed_coverage.sh SEED_DIR TARGET
```

---

## 시각화

전부 `measure_coverage.sh`가 만든 `coverage_over_time.csv`를 읽는다.

| 스크립트 | 용도 |
|---|---|
| `plot_coverage.py` | 타겟별 브랜치 커버리지 시계열. 메인 그래프 |
| `diff_coverage.py` | 베이스라인 대비 **차이** 시계열. 0을 기준으로 대칭인 부호 있는 Y축 |
| `plot_area_bars.py` | 퍼저 쌍별 차이의 면적(net = pos − neg)을 타겟별 막대로 요약 |
| `plot_rotation_coverage.py` | 로테이션 실험(day1_angora, day2_libafl, ...)의 일자별 CSV를 타겟마다 하나의 연속 선으로 잇고, 24시간 배경 밴드를 그날 퍼저 색으로 칠한다 |
| `boxplot.py` / `boxplot_ratio.py` | 최종 커버리지 분포 박스플롯 (절대값 / 비율) |
| `km_curve.py` | Kaplan-Meier 곡선 (`lifelines` 필요) |

```bash
./plot_coverage.py WORKDIR --interval 15
./plot_coverage.py WORKDIR --interval 15 --per-trial --log-x
```

`--interval`은 필수이며 `archive_campaigns.sh`/`measure_coverage.sh`에 준 분과
같아야 한다. `--median`, `--only-average`, `--per-trial`, `--log-x`로 표현을 바꾼다.

---

## 분석 디렉토리

### coverage_analysis/

입력 단위 커버리지 분석. 자세한 내용은 `COVERAGE_ANALYSIS.md`, 조건 분석은
`cond_README.md`.

| 파일 | 용도 |
|---|---|
| `single_input_coverage.sh` | 입력 1개의 HTML 커버리지 리포트 |
| `find_coverage_increasing_inputs.sh` | 어떤 입력이 새 브랜치를 열었는지 |
| `find_exclusive_coverage.sh` | 한쪽 퍼저만 연 브랜치 |
| `measure_aggregate_coverage.sh` | 전 trial 누적 커버리지 |
| `cond_analyze.py` / `cond_annotate.py` / `condstate.py` | 조건 분기 상태 분석 |
| `entrypoint_offline.sh`, `dynamorio.sh` | 보조 |

```bash
./coverage_analysis/single_input_coverage.sh <입력파일> <타겟> <출력디렉토리>
xdg-open <출력디렉토리>/html/index.html
```

입력 경로의 콜론(`id:000042`)은 Docker 볼륨 마운트 제약 때문에 콜론 없는 임시
파일로 복사한 뒤 넘긴다.

### pattern_analysis/

`.dtaint`의 taint 패턴 분석. `README.md` 참조.
`analyze_patterns.py`, `analyze_distinct.py`, `compare_pattern_functions.py`.

---

## 유틸리티

### measure_memory.sh

실행 중인 퍼저 컨테이너의 메모리 사용량을 5가지 각도로 출력한다.

```bash
./measure_memory.sh <컨테이너 이름 또는 id>
./measure_memory.sh          # 인수 없으면 실행 중인 캠페인 컨테이너를 자동 탐지
```

자동 탐지는 **이미지**로 찾는다 — `unifuzz/unibench:*`에서 뜬 컨테이너 중
`:coverage`를 뺀 것. 컨테이너 이름(`<fuzzer>-<target>-<nanos>`)으로 찾으면 퍼저
팔이 바뀔 때마다 낡기 때문이다. 후보가 여럿이면 목록만 보여주고 멈춘다. 조용히
하나를 골랐다가 엉뚱한 캠페인을 재는 쪽이 더 나쁘다.

| 항목 | 내용 |
|---|---|
| [1] cgroup 전체 | `memory.current` — 컨테이너 총 사용량 중 가장 정확 |
| [2] memory.stat | anon / file / shmem / kernel 분류 |
| [3] SHM 세그먼트 | 컨테이너 IPC 네임스페이스의 공유 메모리 |
| [4] 프로세스별 RSS | 호스트 `/proc` 기준 |
| [5] docker stats | MEM Usage, MEM %, CPU % |

- cgroup v2 전제.
- [3]은 `docker exec`를 쓰므로 컨테이너가 살아 있어야 한다.
- RSS 합계는 SHM을 중복 계산하므로 실제보다 크게 나온다.
