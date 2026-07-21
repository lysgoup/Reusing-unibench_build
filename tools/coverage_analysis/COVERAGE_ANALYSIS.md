# Coverage Analysis Scripts

퍼징 실험 결과에 대한 커버리지 측정 및 분석 스크립트 모음.

---

## 전체 워크플로우

```
[1] find_coverage_increasing_inputs.sh          단일 trial 커버리지 분석
        ↓
[2] measure_aggregate_coverage.sh    전체 실험의 모든 fuzzer+target 누적 커버리지 측정
        ↓
[3] compare_coverage.sh          퍼저 간 exclusive 브랜치 비교
        ↓
[4] filter_exclusive_coverage.sh  특정 trial에서 exclusive 브랜치를 찾은 입력만 필터링
[5] annotate_exclusive_coverage.sh  exclusive 브랜치를 어느 trial의 어느 입력이 커버했는지 주석 추가
```

---

## 스크립트 상세

### 1. `find_coverage_increasing_inputs.sh`

실험이 끝난 단일 trial의 queue를 분석해, 어떤 입력이 새로운 브랜치를 커버했는지 기록한다.

**사전 조건**: `unifuzz/unibench:coverage` Docker 이미지가 빌드되어 있어야 함.

```bash
./tools/coverage_analysis/find_coverage_increasing_inputs.sh FINDINGS_DIR SEED_COUNT TARGET
```

| 인자 | 설명 |
|------|------|
| `FINDINGS_DIR` | 퍼저 findings 디렉토리 (`queue/` 포함) |
| `SEED_COUNT` | 초기 seed 입력 수 |
| `TARGET` | 타겟 프로그램 이름 (`targets.conf` 기준) |

**동작**:
1. `queue/`의 파일을 id 순으로 정렬
2. `id:000000` ~ `id:{SEED_COUNT-1}` (seed) 전부 실행 → baseline 커버리지 측정
3. 이후 입력을 하나씩 실행하며 새로운 브랜치가 생기면 기록

**출력**: `FINDINGS_DIR/coverage_analysis.txt`

```
2105                                        ← seed 실행 후 유니크 브랜치 수
001726                                      ← 새 브랜치를 커버한 입력 id
  /unibench/jq-1.5/jv_dtoa.c:2796:1:3     ← 새로 커버된 브랜치 (파일:줄:블록:브랜치)
001859
  /unibench/jq-1.5/jv_dtoa.c:974:0:1
  /unibench/jq-1.5/jv_dtoa.c:2051:0:0
```

**예시**:
```bash
./tools/coverage_analysis/find_coverage_increasing_inputs.sh \
  experiments/_storfuzz/ar/angora/imginfo/0/findings \
  30 \
  imginfo
```

---

### 2. `measure_aggregate_coverage.sh`

실험 디렉토리 전체를 순회하며, 각 `fuzzer+target` 조합의 **모든 trial 입력을 합산**해 누적 커버리지를 측정한다.

```bash
./tools/coverage_analysis/measure_aggregate_coverage.sh WORKDIR
```

| 인자 | 설명 |
|------|------|
| `WORKDIR` | 메인 실험 디렉토리 (`ar/` 포함) |

**탐색 경로**: `WORKDIR/ar/{FUZZER}/{TARGET}/` 아래 모든 trial

**동작**:
1. 각 `{FUZZER}/{TARGET}/` 단위로 Docker 컨테이너 실행
2. 모든 trial의 `findings/queue/` 입력을 id 순으로 실행 (gcov 누적)
3. lcov로 최종 커버리지 캡처

**출력** (per fuzzer+target):
- `ar/{FUZZER}/{TARGET}/coverage.info` — lcov 원본 데이터 (브랜치 비교에 사용)
- `ar/{FUZZER}/{TARGET}/coverage_all_trials.txt` — 요약 수치

```
branch_hit:   4823
branch_total: 57470
line_hit:     12345
line_total:   28000
total_inputs: 16842
```

이미 `coverage_all_trials.txt`가 존재하는 조합은 건너뜀.

**예시**:
```bash
./tools/coverage_analysis/measure_aggregate_coverage.sh experiments/_storfuzz
```

---

### 3. `compare_coverage.sh`

`measure_aggregate_coverage.sh`로 생성된 `coverage.info` 파일들을 비교해, 각 퍼저가 **독점적으로** 커버한 브랜치를 찾는다.

```bash
./tools/compare_coverage.sh WORKDIR FUZZER1 FUZZER2 [FUZZER3 ...]
```

| 인자 | 설명 |
|------|------|
| `WORKDIR` | 메인 실험 디렉토리 |
| `FUZZER*` | 비교할 퍼저 이름 (2개 이상) |

**사전 조건**: `measure_aggregate_coverage.sh` 실행 완료 (`coverage.info` 존재)

**동작**: 각 타겟별로 퍼저들의 커버드 브랜치 집합을 비교
- `A exclusive` = A가 커버했으나 B, C 어느 것도 커버하지 않은 브랜치

**출력**: `WORKDIR/coverage_comparison/{TARGET}/`

| 파일 | 내용 |
|------|------|
| `summary.txt` | 퍼저별 총 브랜치 수 및 exclusive 수 |
| `branches_{FUZZER}.txt` | 해당 퍼저가 커버한 전체 브랜치 목록 |
| `exclusive_{FUZZER}.txt` | 해당 퍼저만이 커버한 브랜치 목록 |

`summary.txt` 예시:
```
angora                          total:   4823  exclusive:    142
angora-reusing                  total:   5104  exclusive:    287
forkserver_storfuzz             total:   4601  exclusive:     89
```

**예시**:
```bash
./tools/compare_coverage.sh experiments/_storfuzz angora angora-reusing forkserver_storfuzz
```

---

### 4. `filter_exclusive_coverage.sh`

`coverage_analysis.txt`에서 **exclusive 브랜치를 하나라도 커버한 입력**만 남겨 새 파일을 만든다.

```bash
./tools/filter_exclusive_coverage.sh COVERAGE_ANALYSIS_TXT EXCLUSIVE_TXT
```

| 인자 | 설명 |
|------|------|
| `COVERAGE_ANALYSIS_TXT` | `find_coverage_increasing_inputs.sh`가 생성한 파일 |
| `EXCLUSIVE_TXT` | `compare_coverage.sh`가 생성한 `exclusive_*.txt` |

**출력**: `COVERAGE_ANALYSIS_TXT`와 같은 디렉토리에 `coverage_analysis_exclusive.txt`

형식은 `coverage_analysis.txt`와 동일하되, exclusive 브랜치를 포함한 입력만 포함됨.

**예시**:
```bash
./tools/filter_exclusive_coverage.sh \
  experiments/_storfuzz/ar/angora-reusing/jq/0/findings/coverage_analysis.txt \
  experiments/_storfuzz/coverage_comparison/jq/exclusive_angora-reusing.txt
```

---

### 5. `annotate_exclusive_coverage.sh`

`exclusive_*.txt`의 각 브랜치 옆에, 해당 브랜치를 커버한 **trial 번호와 입력 id**를 주석으로 추가한다.

```bash
./tools/annotate_exclusive_coverage.sh EXCLUSIVE_TXT TRIALS_DIR
```

| 인자 | 설명 |
|------|------|
| `EXCLUSIVE_TXT` | `compare_coverage.sh`가 생성한 `exclusive_*.txt` |
| `TRIALS_DIR` | trial 서브디렉토리들이 있는 디렉토리 (`ar/{FUZZER}/{TARGET}/`) |

**사전 조건**: 각 trial에 `findings/coverage_analysis.txt` 존재 (`find_coverage_increasing_inputs.sh` 실행 완료)

**출력**: `EXCLUSIVE_TXT`와 같은 디렉토리에 `{원본파일명}_annotated.txt`

```
/unibench/jq-1.5/jv_dtoa.c:2053:0:0    0-001859    2-001923
/unibench/jq-1.5/jv_dtoa.c:2095:1:2    1-001832
/unibench/jq-1.5/jv_dtoa.c:3172:0:1
```

- `0-001859` : trial 0의 입력 id:001859가 해당 브랜치를 커버
- 여러 trial에서 커버된 경우 공백으로 구분하여 나열
- annotation 없는 줄: 어느 trial의 `coverage_analysis.txt`에도 기록되지 않은 브랜치

**예시**:
```bash
./tools/annotate_exclusive_coverage.sh \
  experiments/_storfuzz/coverage_comparison/jq/exclusive_angora-reusing.txt \
  experiments/_storfuzz/ar/angora-reusing/jq/
```

---

## 실행 순서 요약

```bash
# 0. Docker 이미지 빌드 (최초 1회)
FUZZER=coverage ./tools/build.sh

# 1. 단일 trial 분석 (필요한 경우)
./tools/coverage_analysis/find_coverage_increasing_inputs.sh <findings_dir> <seed_count> <target>

# 2. 전체 실험 누적 커버리지 측정
./tools/coverage_analysis/measure_aggregate_coverage.sh experiments/_storfuzz

# 3. 퍼저 간 exclusive 브랜치 비교
./tools/compare_coverage.sh experiments/_storfuzz angora angora-reusing forkserver_storfuzz

# 4. (선택) 특정 trial에서 exclusive 브랜치를 찾은 입력만 필터링
./tools/filter_exclusive_coverage.sh \
  experiments/_storfuzz/ar/angora-reusing/jq/0/findings/coverage_analysis.txt \
  experiments/_storfuzz/coverage_comparison/jq/exclusive_angora-reusing.txt

# 5. (선택) exclusive 브랜치에 trial-id 주석 추가
./tools/annotate_exclusive_coverage.sh \
  experiments/_storfuzz/coverage_comparison/jq/exclusive_angora-reusing.txt \
  experiments/_storfuzz/ar/angora-reusing/jq/
```

---

## 컨테이너 entrypoint (내부 사용)

Docker 컨테이너 안에서 실행되는 스크립트로, 직접 호출하지 않는다.

| 파일 | 호출처 |
|------|--------|
| `volume/coverage/entrypoint_find_coverage_increasing_inputs.sh` | `find_coverage_increasing_inputs.sh` |
| `volume/coverage/entrypoint_measure_aggregate_coverage.sh` | `measure_aggregate_coverage.sh` |

**마운트 구조** (`find_coverage_increasing_inputs.sh` 기준):
```
host: FINDINGS_DIR          → container: /findings
host: tools/volume/         → container: /volume
```

**커버리지 바이너리 경로** (컨테이너 내부): `/d/p/cov/{TARGET}`

**타겟 설정 파일**: `/volume/targets.conf` (`{target}_args`, `{target}_source_dir` 등 정의)
