# Reusing-unibench 스크립트 문서

이 문서는 `tools/` 디렉토리 하위의 모든 스크립트와 설정 파일의 역할 및 사용법을 설명합니다.

---

## 목차

1. [전체 구조 개요](#전체-구조-개요)
2. [설정 파일](#설정-파일)
   - [captainrc](#captainrc)
   - [captainrc_saturation](#captainrc_saturation)
   - [captainrc_forkserver](#captainrc_forkserver)
   - [volume/targets.conf](#volumetargetsconf)
3. [캠페인 실행 스크립트](#캠페인-실행-스크립트)
   - [run.sh](#runsh)
   - [build.sh](#buildsh)
   - [start.sh](#startsh)
   - [common.sh](#commonsh)
4. [커버리지 측정 스크립트](#커버리지-측정-스크립트)
   - [measure_coverage.sh](#measure_coveragesh)
   - [make_saturated_seed.sh](#make_saturated_seedsh)
   - [coverage/single_input_coverage.sh](#coveragesingle_input_coveragesh)
   - [archive_queue.sh](#archive_queuesh)
5. [컨테이너 내부 엔트리포인트](#컨테이너-내부-엔트리포인트)
   - [volume/coverage/entrypoint.sh](#volumecoverageentrypointsh)
   - [volume/coverage/entrypoint_for_saturation.sh](#volumecoverageentrypoint_for_saturationsh)
   - [volume/coverage/entrypoint_single_coverage.sh](#volumecoverageentrypoint_single_coveragesh)
   - [volume/coverage/entrypoint_analyze.sh](#volumecoverageentrypoint_analyzesh)
   - [volume/coverage/entrypoint_batch_analyze.sh](#volumecoverageentrypoint_batch_analyzesh)
6. [유틸리티 스크립트](#유틸리티-스크립트)
   - [measure_memory.sh](#measure_memorysh)

---

## 전체 구조 개요

```
tools/
├── run.sh                     # 퍼저 캠페인 전체 실행 (진입점)
├── build.sh                   # Docker 이미지 빌드
├── start.sh                   # 단일 퍼저 컨테이너 실행
├── common.sh                  # 공통 유틸리티 함수
├── captainrc                  # 기본 캠페인 설정
├── captainrc_saturation       # 포화도 기반 캠페인 설정
├── captainrc_forkserver       # forkserver 퍼저 캠페인 설정
├── measure_coverage.sh        # 실시간 커버리지 측정 (archive 기반)
├── make_saturated_seed.sh     # 포화도 기반 커버리지 측정
├── measure_memory.sh          # 컨테이너 메모리 사용량 측정
├── archive_queue.sh           # 퍼저 큐를 주기적으로 tar.gz 아카이브
├── coverage/
│   └── single_input_coverage.sh  # 단일 입력 커버리지 HTML 리포트 생성
├── seeds/                     # 타겟별 초기 시드 디렉토리
└── volume/                    # 컨테이너에 마운트되는 볼륨
    ├── targets.conf            # 타겟 프로그램별 인수/경로 정의
    └── coverage/
        ├── entrypoint.sh                  # 주기적 커버리지 측정 (archive 기반)
        ├── entrypoint_for_saturation.sh   # 포화도 감지 커버리지 측정
        ├── entrypoint_single_coverage.sh  # 단일 입력 커버리지 측정
        ├── entrypoint_analyze.sh          # 큐 파일 순서별 커버리지 분석
        └── entrypoint_batch_analyze.sh    # 전체 trial 누적 커버리지 분석
```

Docker 이미지: `unifuzz/unibench:<fuzzer>`, `unifuzz/unibench:coverage`

---

## 설정 파일

### captainrc

**경로**: `tools/captainrc`

`run.sh`가 소싱하는 Bash 형식의 설정 파일. 캠페인의 핵심 파라미터를 정의한다.

#### 필수 변수

| 변수 | 설명 |
|------|------|
| `WORKDIR` | 캠페인 결과물이 저장될 디렉토리 경로 |
| `REPEAT` | 타겟당 캠페인 반복 횟수 |
| `FUZZERS` | 실행할 퍼저 이름 배열 |

#### 선택 변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `WORKER_POOL` | 전체 논리 코어 | 캠페인에 사용할 CPU 코어 번호 목록 (공백 구분) |
| `WORKER_MODE` | `1` | CPU 할당 단위: `1`=논리코어, `2`=물리코어, `3`=소켓 |
| `WORKERS` | 전체 코어 수 | 사용할 최대 워커 수 |
| `CAMPAIGN_WORKERS` | `1` | 캠페인 1개에 할당할 코어 수 |
| `TIMEOUT` | 무제한 | 캠페인 실행 시간 (`5m`, `2h`, `1d` 형식) |
| `<fuzzer>_TARGETS` | — | 퍼저별 타겟 목록 (미설정 시 전체) |
| `<fuzzer>_<target>_FUZZARGS` | — | 특정 퍼저+타겟 조합의 추가 인수 |
| `<target>_SEED` | — | 타겟별 커스텀 시드 디렉토리 절대 경로 |
| `<target>_QUEUE_FILE` | — | 타겟별 큐 파일 경로 (restore용) |
| `<fuzzer>_CAMPAIGN_WORKERS` | `CAMPAIGN_WORKERS` | 퍼저별 캠페인 워커 수 오버라이드 |

#### 예시

```bash
WORKDIR=../experiments/_test
REPEAT=5
WORKER_POOL="$(seq 80 100)"
TIMEOUT=24h

FUZZERS=(angora angora-reusing)
angora_TARGETS=(exiv2 jq)
angora-reusing_TARGETS=(libpng_read_fuzzer)

libpng_read_fuzzer_SEED="/path/to/custom/seeds/libpng"
```

---

### captainrc_saturation

**경로**: `tools/captainrc_saturation`

커버리지 포화도 감지를 위한 짧은 캠페인 설정. `make_saturated_seed.sh`와 함께 사용하며, 포화된 큐를 다음 실험의 시드로 재활용하기 위한 용도이다.

```bash
WORKDIR=../_saturation
REPEAT=5
WORKER_POOL="$(seq 45 191)"
FUZZERS=(angora)
angora_TARGETS=(jhead)
```

---

### captainrc_forkserver

**경로**: `tools/captainrc_forkserver`

`forkserver_libafl`, `forkserver_storfuzz` 퍼저 실험용 설정. 타겟별 시드 경로를 절대 경로로 지정한다.

```bash
WORKDIR=../_result
REPEAT=2
WORKER_POOL="0 1 2 3 4 5 6 7 8 9 10 11"
TIMEOUT=24h
FUZZERS=(forkserver_libafl)
forkserver_libafl_TARGETS=(exiv2 imginfo jq mp3gain pdftotext)

exiv2_SEED="/path/to/seeds/exiv2"
jq_SEED="/path/to/seeds/jq"
```

---

### volume/targets.conf

**경로**: `tools/volume/targets.conf`

타겟 프로그램의 실행 인수, 시드 디렉토리, 소스 디렉토리를 정의한다. 컨테이너 내부에서 `/volume/targets.conf`로 마운트되어 모든 커버리지 엔트리포인트가 소싱한다.

#### 변수 네이밍 규칙

하이픈(`-`)은 언더스코어(`_`)로 변환하여 변수명에 사용한다.

| 변수 패턴 | 설명 |
|-----------|------|
| `<target>_args` | 프로그램 실행 인수 배열. `@@`는 입력 파일 경로로 치환된다 |
| `<target>_seed_dir` | 시드 디렉토리 이름 (컨테이너 내 `/seeds/` 하위) |
| `<target>_source_dir` | lcov가 `.gcno`/`.gcda` 파일을 찾을 소스 디렉토리 (컨테이너 내 절대 경로) |
| `<target>_stdin_from_file` | `1`로 설정 시 입력 파일을 stdin으로 전달 (`sqlite3` 등) |

#### 지원 타겟 목록

| 타겟 | 인수 패턴 | 비고 |
|------|-----------|------|
| `libpng_read_fuzzer` | `@@` | libpng OSS-Fuzz 하네스 |
| `exiv2` | `@@` | |
| `tiffsplit` | `@@` | |
| `mp3gain` | `@@` | |
| `wav2swf` | `-o /dev/null @@` | |
| `pdftotext` | `@@ /dev/null` | |
| `infotocap` | `-o /dev/null @@` | |
| `mp42aac` | `@@ /dev/null` | |
| `flvmeta` | `@@` | |
| `objdump` | `-S @@` | |
| `tcpdump` | `-e -vv -nr @@` | |
| `ffmpeg` | `-y -i @@ -c:v mpeg4 -c:a copy -f mp4 /dev/null` | |
| `gdk_pixbuf_pixdata` | `@@ /dev/null` | |
| `cflow` | `@@` | |
| `nm` | `-A -a -l -S -s ... @@` | |
| `sqlite3` | (없음) | stdin 방식, `stdin_from_file=1` |
| `lame3_99_5` | `@@ /dev/null` | |
| `jhead` | `@@` | |
| `imginfo` | `-f @@` | |
| `jq` | `. @@` | |
| `mujs` | `@@` | |

---

## 캠페인 실행 스크립트

### run.sh

**경로**: `tools/run.sh`

퍼저 캠페인의 최상위 진입점. `captainrc`를 읽고 Docker 이미지를 빌드한 뒤, 지정한 퍼저/타겟 조합에 대해 `REPEAT`번 캠페인을 병렬로 실행한다.

#### 사용법

```bash
./tools/run.sh [captainrc_path]
# captainrc_path 생략 시 ./captainrc 사용

# 예시
./tools/run.sh
./tools/run.sh ./captainrc_saturation
./tools/run.sh ./captainrc_forkserver
```

#### 동작 흐름

```
captainrc 로드
    ↓
CPU 풀 결정 (WORKER_POOL 또는 lscpu 자동 탐지)
    ↓
WORKDIR 하위 디렉토리 생성 (ar/, cache/, log/, poc/, lock/)
    ↓
각 FUZZER에 대해 Docker 이미지 빌드 (build.sh 호출)
    ↓
FUZZER × TARGET × REPEAT 조합에 대해:
  - allocate_workers()로 CPU 코어 점유 (flock 기반 mutex)
  - start_campaign() → start.sh 실행 (백그라운드)
    ↓
모든 백그라운드 작업 완료 대기
```

#### 디렉토리 레이아웃

```
WORKDIR/
├── ar/          # 캠페인 완료 후 findings가 이동되는 아카이브
│   └── <fuzzer>/<target>/<id>/
├── cache/       # 실행 중 컨테이너의 live 공유 볼륨
│   └── <fuzzer>/<target>/<id>/
├── log/         # 컨테이너 및 빌드 로그
├── poc/         # PoC 파일 (미사용)
└── lock/        # CPU 코어 점유 lock 파일
```

#### CPU 할당 방식

- `WORKER_POOL` 내 코어에 대해 lock 파일(`lock/unibench_cpu_<N>`)을 통해 exclusive 점유
- `CAMPAIGN_WORKERS > 1`이면 캠페인 1개가 여러 코어를 점유
- `inotifywait`으로 lock 해제를 이벤트 기반으로 감지

---

### build.sh

**경로**: `tools/build.sh`

퍼저 Docker 이미지를 빌드한다. `angora`와 `angora-reusing`은 소스 변경 여부를 SHA256 해시로 감지해 불필요한 전체 재빌드를 방지한다.

#### 사용법

```bash
FUZZER=<fuzzer_name> ./tools/build.sh

# 예시
FUZZER=angora ./tools/build.sh
FUZZER=angora-reusing ./tools/build.sh
FUZZER=coverage ./tools/build.sh
```

#### 빌드 전략

**angora / angora-reusing (해시 기반 스마트 빌드)**

소스 디렉토리를 세 구성 요소로 나눠 해시를 계산하고 `_build_cache/` 에 저장한다.

| 변경 범위 | 빌드 단계 |
|-----------|-----------|
| `llvm_mode` 변경 | 전체 재빌드 (step1 → step2 → base → fuzzer) |
| `fuzzer` 또는 `common` 변경 | fuzzer 이미지만 재빌드 (`angora_fuzzer_only/Dockerfile`) |
| 변경 없음 | 빌드 스킵 |

**기타 퍼저**

```bash
docker build -t "unifuzz/unibench:<fuzzer>" -f "<fuzzer>/Dockerfile" .
```

#### 빌드 단계 (angora-reusing 전체 재빌드)

```
yunseo/angora-reusing          ← Angora 베이스 이미지
unifuzz/unibench:angora-reusing_step1   ← LLVM 빌드
unifuzz/unibench:angora-reusing_step2   ← 타겟 프로그램 빌드
unifuzz/unibench:angora-reusing-base    ← 퍼저+타겟 통합
unifuzz/unibench:angora-reusing         ← 최종 실행 이미지
```

---

### start.sh

**경로**: `tools/start.sh`

단일 퍼저 캠페인을 Docker 컨테이너로 실행한다. `run.sh`가 내부적으로 호출하며, 직접 실행하면 인터랙티브 모드로 동작한다.

#### 사용법 (직접 실행 시)

```bash
FUZZER=angora-reusing \
TARGET=jq \
SHARED=/path/to/shared/dir \
TIMEOUT=24h \
./tools/start.sh

# 시드 디렉토리 지정
FUZZER=angora-reusing \
TARGET=libpng_read_fuzzer \
SHARED=/path/to/shared \
SEED=/path/to/seeds \
TIMEOUT=1h \
./tools/start.sh
```

#### 환경 변수

| 변수 | 필수 | 설명 |
|------|------|------|
| `FUZZER` | 필수 | 퍼저 이름 (`unifuzz/unibench:<FUZZER>` 이미지 사용) |
| `TARGET` | 필수 | 타겟 프로그램 이름 |
| `SHARED` | 필수 | 컨테이너 내 `/unibench_shared`로 마운트될 호스트 디렉토리 |
| `TIMEOUT` | 선택 | 실행 시간 제한 (미설정 시 무기한) |
| `SEED` | 선택 | 커스텀 시드 디렉토리 (`/customized_seed`로 마운트) |
| `QUEUE_FILE` | 선택 | 복원용 큐 파일 (`/restore/cond_queue.csv:ro`로 마운트) |
| `FUZZARGS` | 선택 | 퍼저에 전달할 추가 인수 |
| `AFFINITY` | 선택 | CPU 코어 바인딩 (`--cpuset-cpus`) |
| `ENTRYPOINT` | 선택 | 커스텀 엔트리포인트 (기본: `/volume/entrypoint.sh`) |
| `ROOT_MODE` | 선택 | 설정 시 root로 실행 (기본: 호스트 UID/GID 사용) |

#### 실행 모드

- **인터랙티브** (TTY 있을 때): `docker run -it` — 컨테이너 로그를 터미널에 직접 출력
- **백그라운드** (TTY 없을 때): `docker run -dt` — 컨테이너 ID를 반환하고 `docker logs -f`로 로그 스트리밍

---

### common.sh

**경로**: `tools/common.sh`

`run.sh`, `start.sh`, `build.sh` 등이 소싱하는 공통 유틸리티 함수 모음.

#### 제공 함수

| 함수 | 설명 |
|------|------|
| `echo_time <message>` | `[YYYY-MM-DD HH:MM] message` 형식으로 타임스탬프 포함 출력 |
| `contains_element <val> <array...>` | 배열에 값이 포함되어 있으면 0 반환 |
| `get_var_or_default <key...>` | `key1_key2_...` 패턴으로 변수를 탐색하고, 없으면 `DEFAULT_key2_...` 패턴으로 폴백 |

`get_var_or_default`는 `captainrc`의 퍼저/타겟별 설정을 계층적으로 조회할 때 사용된다. 예를 들어 `get_var_or_default angora jq FUZZARGS`는 `angora_jq_FUZZARGS` → `DEFAULT_jq_FUZZARGS` → `jq_FUZZARGS` 순으로 탐색한다.

---

## 커버리지 측정 스크립트

### measure_coverage.sh

**경로**: `tools/measure_coverage.sh`

실행 중인 퍼저 캠페인의 커버리지를 주기적으로 측정한다. `archive_queue.sh`로 큐를 아카이브하고, `unifuzz/unibench:coverage` 컨테이너에서 아카이브를 처리한다.

#### 사용법

```bash
./tools/measure_coverage.sh WORKDIR INTERVAL MAX_ITERATIONS [SATURATION_WINDOW MIN_ITERATIONS]

# 예시: 900초(15분) 간격, 최대 100번 측정
./tools/measure_coverage.sh ../experiments/_test 900 100

# 포화도 감지: 20번 연속 변화 없으면 종료, 최소 10번은 보장
./tools/measure_coverage.sh ../experiments/_test 900 200 20 10
```

#### 인수

| 인수 | 설명 |
|------|------|
| `WORKDIR` | `run.sh`에 사용한 것과 동일한 작업 디렉토리 |
| `INTERVAL` | 아카이브 간격 (초) |
| `MAX_ITERATIONS` | 최대 측정 횟수 (dryrun 제외) |
| `SATURATION_WINDOW` | (선택) 이 횟수만큼 브랜치 커버리지가 변하지 않으면 캠페인 종료 |
| `MIN_ITERATIONS` | (`SATURATION_WINDOW` 설정 시 필수) 포화도 카운팅 시작 전 최소 반복 횟수 |

#### 동작 흐름

```
coverage Docker 이미지 빌드
    ↓
WORKDIR/cache/ 감시 루프 (10초마다)
    ↓
새 캠페인 디렉토리 발견 시:
  - archive_queue.sh 백그라운드 실행
      → INTERVAL초마다 큐를 iter_NNNN.tar.gz로 아카이브
  - coverage 컨테이너 실행 (entrypoint.sh)
      → 각 아카이브의 큐 파일을 모두 실행
      → lcov → genhtml로 HTML 리포트 생성
      → 브랜치 커버리지 변화 추적
    ↓
MAX_ITERATIONS 도달 또는 SATURATION_WINDOW 충족 시:
  - archive_done 신호 파일 생성
  - 해당 캠페인의 퍼저 컨테이너에 SIGINT 전송
```

#### 출력 디렉토리

```
WORKDIR/coverage/<fuzzer>/<target>/<id>/
├── archives/
│   ├── iter_0000.tar.gz
│   ├── iter_0001.tar.gz
│   └── archive_done        # MAX_ITERATIONS 도달 시 생성
├── coverage.info           # 최신 lcov 데이터
├── html/                   # 최신 HTML 리포트
├── coverage.log            # 이터레이션별 커버리지 요약
└── saturation_done         # 포화도 도달 시 생성
```

---

### make_saturated_seed.sh

**경로**: `tools/make_saturated_seed.sh`

`measure_coverage.sh`와 구조는 동일하지만, `entrypoint_for_saturation.sh`를 사용해 큐 전체를 직접 읽고 커버리지 포화도를 감지한다. 포화된 큐를 다음 실험의 시드로 추출하는 것이 목적이다.

#### 사용법

```bash
./tools/make_saturated_seed.sh WORKDIR

# 예시
./tools/make_saturated_seed.sh ../_saturation
```

#### measure_coverage.sh와의 차이점

| 항목 | measure_coverage.sh | make_saturated_seed.sh |
|------|---------------------|------------------------|
| 엔트리포인트 | `entrypoint.sh` (아카이브 기반) | `entrypoint_for_saturation.sh` (큐 직접 읽기) |
| 인수 | INTERVAL, MAX_ITERATIONS 필요 | WORKDIR만 필요 |
| 포화도 파라미터 | captainrc에서 주입 | 엔트리포인트 내 하드코딩 |
| 목적 | 커버리지 시계열 측정 | 포화된 큐 추출 |

---

### coverage/single_input_coverage.sh

**경로**: `tools/coverage/single_input_coverage.sh`

단일 입력 파일 하나를 지정한 타겟에서 실행하고 HTML 커버리지 리포트를 생성한다.

#### 사용법

```bash
./tools/coverage/single_input_coverage.sh INPUT_FILE TARGET OUTPUT_DIR

# 예시
./tools/coverage/single_input_coverage.sh \
    /path/to/id:000042 \
    jq \
    /tmp/my_report

# 리포트 열기
xdg-open /tmp/my_report/html/index.html
```

#### 인수

| 인수 | 설명 |
|------|------|
| `INPUT_FILE` | 실행할 단일 입력 파일 경로 (콜론 포함 경로 자동 처리) |
| `TARGET` | 타겟 이름 (`targets.conf` 기준) |
| `OUTPUT_DIR` | HTML 리포트를 출력할 디렉토리 |

#### 출력

```
OUTPUT_DIR/
├── single.info         # lcov 데이터
└── html/               # HTML 커버리지 리포트
    └── index.html      # 브라우저로 열면 라인/브랜치/함수 커버리지 확인 가능
```

#### 내부 동작

1. `INPUT_FILE`을 콜론 없는 임시 파일로 복사 (Docker 볼륨 마운트 제약 우회)
2. `unifuzz/unibench:coverage` 컨테이너 실행
3. 컨테이너 내에서 `entrypoint_single_coverage.sh` 호출
4. 컨테이너 종료 후 임시 파일 정리

---

### archive_queue.sh

**경로**: `tools/archive_queue.sh`

퍼저가 생성하는 큐 디렉토리를 주기적으로 `tar.gz` 스냅샷으로 아카이브한다. `measure_coverage.sh`가 백그라운드에서 호출한다.

#### 사용법

```bash
./tools/archive_queue.sh CACHE_DIR ARCHIVE_DIR INTERVAL [MAX_ITERATIONS]

# 예시
./tools/archive_queue.sh \
    /workdir/cache/angora/jq/0 \
    /workdir/coverage/angora/jq/0/archives \
    900 \
    100
```

#### 인수

| 인수 | 설명 |
|------|------|
| `CACHE_DIR` | 퍼저 캠페인의 live 공유 디렉토리 (`$CACHEDIR/$FUZZER/$TARGET/$CACHECID`) |
| `ARCHIVE_DIR` | 아카이브 파일을 저장할 디렉토리 |
| `INTERVAL` | 아카이브 간격 (초) |
| `MAX_ITERATIONS` | (선택) 최대 아카이브 횟수. 도달 시 `archive_done` 파일 생성 |

#### 동작 흐름

1. `findings/queue` 또는 `findings/default/queue` 디렉토리 탐색 대기
2. `queue/signal/dryrun_finish` 파일 생성 대기 (dryrun 완료 신호)
3. 매 `INTERVAL`초마다:
   - `CACHE_DIR` 전체를 `iter_NNNN.tar.gz`로 압축
   - 큐 파일 수 로깅
4. `MAX_ITERATIONS` 도달 시 `archive_done` 마커 파일 생성

#### 큐 디렉토리 탐색 규칙

| 퍼저 | 큐 경로 |
|------|---------|
| Angora | `findings/queue/` |
| AFL++ | `findings/default/queue/` |

---

## 컨테이너 내부 엔트리포인트

이 스크립트들은 `unifuzz/unibench:coverage` 컨테이너 내부에서 실행된다. 직접 호출하지 않으며, 호스트 스크립트가 Docker 볼륨 마운트와 함께 `--entrypoint`로 지정한다.

### 공통 마운트 구조

| 컨테이너 경로 | 호스트 원본 | 설명 |
|---------------|-------------|------|
| `/volume` | `tools/volume/` | `targets.conf` 등 설정 파일 |
| `/d/p/cov/<target>` | (이미지 내장) | gcov 계측 커버리지 바이너리 |

---

### volume/coverage/entrypoint.sh

아카이브(`iter_NNNN.tar.gz`) 기반 주기적 커버리지 측정. `measure_coverage.sh`에 의해 실행된다.

#### 마운트

| 컨테이너 경로 | 호스트 원본 |
|---------------|-------------|
| `/coverage_out` | `WORKDIR/coverage/<fuzzer>/<target>/<id>/` |
| `/volume` | `tools/volume/` |

#### 환경 변수

| 변수 | 설명 |
|------|------|
| `TARGET` | 타겟 이름 |
| `MEASUREMENT_INTERVAL` | 측정 간격 (초) |
| `MAX_ITERATIONS` | 최대 반복 횟수 |
| `SATURATION_WINDOW` | (선택) 포화도 감지 윈도우 |
| `MIN_ITERATIONS` | (선택) 포화도 카운팅 최소 반복 |

#### 동작

- `/coverage_out/archives/iter_0000.tar.gz` 생성 대기
- 각 아카이브에서 `findings/queue/id:*` 파일을 추출해 순서대로 실행
- gcov 카운터 리셋 후 전체 큐 재실행 (이터레이션마다 누적이 아닌 스냅샷)
- 브랜치 커버리지 포화도 추적, 조건 충족 시 `saturation_done` 생성

---

### volume/coverage/entrypoint_for_saturation.sh

큐 디렉토리를 직접 폴링하는 포화도 감지 방식. `make_saturated_seed.sh`에 의해 실행된다.

#### 마운트

| 컨테이너 경로 | 호스트 원본 |
|---------------|-------------|
| `/unibench_shared` | `WORKDIR/cache/<fuzzer>/<target>/<id>/` |
| `/coverage_out` | `WORKDIR/coverage/<fuzzer>/<target>/<id>/` |
| `/volume` | `tools/volume/` |

#### 동작

- `dryrun_finish` 신호 파일 대기
- 15분 간격으로 큐 전체 실행 → lcov 캡처 → HTML 리포트 생성
- 내장 파라미터: `saturation_window=96`, `min_iterations=384`, `max_iterations=672` (≈ 7일)
- 포화 또는 최대 반복 도달 시 컨테이너 종료

---

### volume/coverage/entrypoint_single_coverage.sh

단일 입력 파일의 커버리지를 측정하고 HTML 리포트를 생성한다. `coverage/single_input_coverage.sh`에 의해 실행된다.

#### 마운트

| 컨테이너 경로 | 호스트 원본 |
|---------------|-------------|
| `/input` | 측정할 입력 파일 (read-only) |
| `/report` | 결과 출력 디렉토리 |
| `/volume` | `tools/volume/` |

#### 환경 변수

| 변수 | 설명 |
|------|------|
| `TARGET` | 타겟 이름 |

#### 동작

1. gcov 카운터 리셋
2. 단일 입력 실행 (timeout 1초)
3. `lcov --capture` → `/report/single.info`
4. `genhtml` → `/report/html/`
5. 라인/브랜치/함수 커버리지 요약 출력

---

### volume/coverage/entrypoint_analyze.sh

퍼저 큐 파일을 ID 순서대로 하나씩 처리하며, 각 입력이 새로운 브랜치를 커버하는지 추적한다. 어떤 입력이 커버리지를 증가시켰는지 분석하는 데 사용한다.

#### 마운트

| 컨테이너 경로 | 호스트 원본 |
|---------------|-------------|
| `/findings` | 퍼저 findings 디렉토리 (`queue/`가 여기에 존재) |
| `/volume` | `tools/volume/` |

#### 환경 변수

| 변수 | 설명 |
|------|------|
| `TARGET` | 타겟 이름 |
| `SEED_COUNT` | 초기 시드 파일 수 (시드와 퍼저 생성 입력 구분용) |

#### 동작

1. 큐 파일을 ID 순으로 정렬
2. 처음 `SEED_COUNT`개 파일을 모두 실행 → 시드 베이스라인 커버리지 측정
3. 이후 퍼저 생성 입력을 하나씩 처리:
   - 실행 후 `capture_coverage` → 브랜치 수 비교
   - 새 브랜치 발견 시 `diff_branches`로 세부 브랜치 위치 출력
4. 결과를 `/findings/coverage_analysis.txt`에 저장

#### 출력 형식 (`coverage_analysis.txt`)

```
<시드 브랜치 수>
<새 브랜치 커버한 입력 ID>
  <file>:<line>:<block>:<branch>
  ...
<다음 입력 ID>
  ...
```

---

### volume/coverage/entrypoint_batch_analyze.sh

여러 trial의 큐 파일을 한꺼번에 실행해 누적 커버리지를 측정한다.

#### 마운트

| 컨테이너 경로 | 호스트 원본 |
|---------------|-------------|
| `/target_dir` | `WORKDIR/ar/<fuzzer>/<target>/` (trial 서브디렉토리 포함) |
| `/volume` | `tools/volume/` |

#### 환경 변수

| 변수 | 설명 |
|------|------|
| `TARGET` | 타겟 이름 |

#### 동작

1. `/target_dir/*/findings/queue/id:*` 파일을 모든 trial에 대해 수집
2. gcov 카운터 리셋 후 전체 실행
3. lcov 캡처 → 브랜치/라인 커버리지 집계
4. 결과를 `/target_dir/coverage_all_trials.txt`에 저장

#### 출력 형식 (`coverage_all_trials.txt`)

```
branch_hit:   4473
branch_total: 57470
line_hit:     8921
line_total:   23401
total_inputs: 15234
```

---

## 유틸리티 스크립트

### measure_memory.sh

**경로**: `tools/measure_memory.sh`

실행 중인 퍼저 컨테이너의 메모리 사용량을 5가지 방식으로 분석해 출력한다.

#### 사용법

```bash
# 컨테이너 이름/ID 지정
./tools/measure_memory.sh <container_name_or_id>

# angora 컨테이너 자동 탐지
./tools/measure_memory.sh
```

#### 출력 항목

| 항목 | 설명 |
|------|------|
| **[1] cgroup 전체 메모리** | `/sys/fs/cgroup/.../memory.current` — 가장 정확한 컨테이너 총 메모리 사용량 |
| **[2] memory.stat 세부 분류** | anon, file, shmem, kernel 등 항목별 분류 |
| **[3] SHM 세그먼트** | 컨테이너 IPC 네임스페이스 내 공유 메모리 세그먼트 목록 |
| **[4] 프로세스별 RSS** | 호스트 `/proc` 기준 각 프로세스의 Resident Set Size |
| **[5] docker stats 요약** | `MEM Usage`, `MEM %`, `CPU %` |

#### 주의사항

- cgroup v2(`/sys/fs/cgroup/` 계층 구조)를 사용하는 시스템에서 동작한다.
- SHM 항목은 `docker exec`를 사용하므로 컨테이너가 실행 중이어야 한다.
- RSS 합계는 공유 메모리(SHM)를 중복 계산하므로 실제 사용량보다 클 수 있다.
