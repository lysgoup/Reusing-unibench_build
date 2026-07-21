# angora-reusing 효과 분석 (_test 실험 결과 기반)

생성일: 2026-07-01

## 1. 실험 개요

- 대상: unibench 6개 타겟 (exiv2, flvmeta, infotocap, mp3gain, objdump, tiffsplit)
- 비교군: `angora` (원본) vs `angora-reusing` (taint 결과 재사용 기능 추가)
- 반복: 타겟당 10회 (objdump는 분석 진행 중, 일부만 완료)
- 측정: 온라인 fuzzer 로그(`_test/log/`), 오프라인 재실행 커버리지(`_test/coverage/`, `--analysis-mode`), 시간 대비 커버리지 곡선(`_test/graph/data/*_branch_count.txt`)

## 2. 타겟별 결과 요약

| 타겟 | angora-reusing이 angora 최종 커버리지를 따라잡는지 (KM curve) | 종합 평가 |
|---|---|---|
| tiffsplit | 10/10 도달, 0.1~0.5배 시간 (더 빠름) | 좋음 |
| objdump | 5/5 도달, 0.3~0.7배 시간, branch_pct도 우세 (10.1~10.3% vs 10.06~10.09%) | 좋음 |
| mp3gain | 5/5 도달, ~1배 (비슷한 속도) | 비슷 |
| exiv2 | 9/10 도달하지만 1~6배 더 느림, 1건 미도달 | 나쁨 (약함) |
| infotocap | 3/10만 도달, 도달해도 최대 48배 느림 | 나쁨 |
| flvmeta | **10번 중 0번도 도달 못함** | 최악 |

분석 대상: "비슷하거나 낮음" 그룹 = mp3gain, exiv2, infotocap, flvmeta

## 3. 실행 처리량(속도) 비교 (run 0 기준, 동일 wall-clock 시간 내 실행 수)

| 타겟 | angora (r/s) | reusing (r/s) | 총 실행 수 변화 |
|---|---|---|---|
| tiffsplit | 166.5 | 232.0 | +39% (예외적으로 더 빠름) |
| objdump | 45.6 | 40.9 | -9% |
| mp3gain | 124.3 | 81.3 | -32% |
| exiv2 | 96.0 | 68.7 | -26% |
| infotocap | 218.7 | 144.6 | -33% |
| flvmeta | 255.2 | 164.3 | -32% |

angora-reusing은 tiffsplit을 제외한 모든 타겟에서 같은 시간 동안 25~35% 적게 실행함. 이 처리량 손실은 REUSING 전용 단계뿐 아니라 AFL 단계 자체의 초당 실행 수 저하로도 나타남 (예: infotocap은 AFL 단계에 할당된 시간이 baseline과 거의 동일한데도 그 안에서 처리한 실행 수가 16.79m → 11.23m로 33% 감소).

## 4. 원인 분석

### 원인 1 (공통, 코드로 확인됨): 전역 lock + 선형 스캔으로 인한 전 단계 처리량 저하

- `fuzzer/src/search/reusing.rs`: reuse는 조건(condition)의 taint 바이트 **길이 패턴만**(`extract_pattern_merged`, 의미는 보지 않고 세그먼트 길이만 비교) 같으면 과거 다른 조건에서 통했던 critical value를 그대로 재사용.
- `fuzzer/src/depot/label_pattern_tracker.rs`: 모든 스레드가 공유하는 전역 `Mutex<HashMap<Pattern, Vec<CondRecord>>>` (`LABEL_PATTERN_MAP`)에 기록. 새 레코드 삽입 시(`create_single_record`) **같은 패턴의 기존 레코드 전체를 선형 스캔**해서 중복 체크.
- 이 삽입은 `executor.rs:334` (`do_if_has_new`)에서 새 경로를 찾을 때마다 호출되며, AFL/EXPLORE/EXPLOIT 등 **어느 단계에서 찾았든 상관없이** 실행됨 → REUSING 단계만이 아니라 AFL 단계 자체의 처리량까지 저하시킴.
- (검증 필요) 실제 락 대기 시간을 계측하지는 않음. `perf` 또는 락 hold-time 계측으로 추가 확인 가능.

### 원인 2 (exiv2 특이적, 로그로 확인됨): 의미 없는 패턴 재사용으로 인한 hang 폭증

- exiv2의 REUSING 단계만 유독 hang이 많음 (`REUSING | FOUND: 334 - 372 - 178`, 다른 타겟은 대부분 0~2건).
- exiv2(EXIF/TIFF 메타데이터)는 태그ID·오프셋·카운트처럼 **길이는 같지만 의미가 다른 필드**가 많은 포맷 → 길이 패턴만으로 값을 재사용하면 엉뚱한 필드에 큰 count/length 값이 꽂혀 파서가 무한루프/거대 할당에 빠질 가능성.
- hang은 timeout만큼 시간을 통째로 소모하므로 소수의 hang만으로도 전체 처리량에 큰 타격.
- (검증 필요) 실제 hang을 유발한 입력을 재현해서 어떤 필드에 어떤 값이 잘못 꽂혔는지 직접 확인 필요.

### 원인 3 (infotocap·flvmeta 특이적): 애초에 reuse가 개입할 여지가 거의 없음

`label_patterns.txt` 헤더 비교:

| 타겟 | distinct 패턴 수 | 레코드 수 | 결과 |
|---|---|---|---|
| objdump | 6037 | 41226 | 좋음 |
| mp3gain | 854 | 10336 | 비슷 |
| exiv2 | 109 | 6352 | 나쁨 |
| tiffsplit | 12 | 751 | 좋음 (예외) |
| infotocap | 64 | 602 | 나쁨 |
| flvmeta | 9 | 1030 | 최악 |

- infotocap·flvmeta는 로그 스테이지별 FOUND 값 기준 **전체 발견 경로의 99.7~99.9%가 `OtherFuzz`(taint로 못 다루는 조건) 단계**에서 나오고, AFL/EXPLORE/REUSING이 다루는 나머지는 극소수.
- 즉 이 두 타겟은 커버리지가 초반에 거의 결정되고 나머지는 사실상 포화 상태라, reuse가 기여할 대상 자체가 거의 없는 상태에서 원인 1의 처리량 손실만 순손해로 남음.
- 단, tiffsplit도 패턴 수가 9~12개로 flvmeta와 비슷한데 결과는 좋으므로, 이 지표 하나만으로 전부 설명되지는 않음 (타겟별 파일 포맷 특성 차이가 더 크게 작용하는 것으로 보임).

## 5. mp3gain 심층 확인 (5-trial 검증 완료): reuse는 real coverage/버그를 하나도 늘리지 못했다

여러 단계를 거쳐 검증했고, 최종 결론은 **"효과 없음"이 맞다** (중간에 "효과 있음"으로 뒤집혔다가 다시 정정됨 — 아래 과정 기록).

### 5.1 처음 발견: mut_op 분포상으로는 Reusing이 활발해 보였음

`analysis_1.csv`(새 입력마다 `new_input_id, parent_input_id, mut_op, reusing_detail` 기록, `executor.rs:565` 부근)를 까보니, 5개 trial 전부에서 new_input_id가 **9384**부터 시작 — `_saturation/ar/angora/mp3gain/saturated_seed`의 파일 수(9384개)와 정확히 일치. 즉 이건 24시간 전체 캠페인의 순수 증분 발견분이며, 신규 입력의 60~73%가 "Reusing" mut_op였고 baseline(11~19개)보다 총 신규 입력 수도 2배 가까이 많았다 (21~43개).

### 5.2 반전: 그 "새 입력"들은 call-context만 다른 재방문이었다

`cond_queue.csv`(cmpid, **context**, order, belong 등 포함)로 Reusing이 만든 입력들의 조건을 역추적한 결과, **85%(444/523)가 이미 알려진 cmpid를 다른 호출 context로 재방문**한 것이었음. 게다가 distinct (cmpid, context) 쌍 자체가 angora(1016)와 angora-reusing(1018)이 5개 trial 전부에서 거의 동일 — depot의 taint 조건 추적 관점에서도 두 fuzzer가 도달한 조건 공간은 사실상 같았다.

### 5.3 로그 통계 버그 발견

로그의 `FOUND | CRASHES` 값과 실제 `crashes/` 폴더 파일 수를 대조하니, **angora-reusing만 로그가 디스크의 절반 수준으로 크래시를 과소집계**하는 버그를 발견 (`fuzzer/src/search/reusing.rs`의 `apply_reusing_mutation`이 reuse 시도 후 `local_stats.restore(snapshot)`으로 되돌리는데, 이게 `num_crashes`/`num_hangs`/`num_inputs`까지 되돌려서 `chart.rs`의 `sync_from_local`이 반영하기 전에 지워버림 — 크래시 파일 자체는 `depot.save()`가 독립적으로 이미 저장해서 디스크엔 남음). **로그의 실시간 통계는 angora-reusing에서 신뢰 불가, 디스크 파일 수를 써야 함.**

### 5.4 최종 검증: gcov 기반 real coverage 재실행 + gdb 기반 crash 재분류 (5-trial 전체)

`tools/coverage_analysis/find_coverage_increasing_inputs.sh`로 seed(9384개) + queue 전체를 gcov 계측 바이너리로 재실행하고, 별도 격리 컨테이너에서 crash 파일 전체(584~701개/trial/fuzzer)를 gdb로 재실행해 (시그널, crash 지점, 호출자)로 재버킷했다.

**실제 커버리지 (gcov, 5개 trial 전부):**

| trial | 최종 branch 수 (angora / reusing) | 새로 커버한 위치 |
|---|---|---|
| 0 | 1070 / 1070 | 완전 동일 |
| 1 | 1070 / 1070 | 완전 동일 |
| 2 | 1070 / 1070 | 완전 동일 |
| 3 | 1071 / 1071 | 완전 동일 |
| 4 | 1070 / 1070 | 완전 동일 |

**크래시 유니크 버그 수 (gdb 재실행, 5개 trial 전부):**

| trial | angora | reusing |
|---|---|---|
| 0 | 3 | 4 |
| 1~4 | 4 | 4 |

mp3gain에는 정확히 **4개의 크래시 버그**(`III_dequantize_sample@layer3.c:904` ×2개 호출경로, `WriteMP3GainAPETag@apetag.c:636`, 희귀 버그 `main@mp3gain.c:2599`)만 존재하고, 양쪽 fuzzer가 5개 trial 거의 전부에서 4개를 모두 찾는다 (trial 0의 angora만 희귀 버그를 놓쳤는데, 발생확률이 워낙 낮아서 우연임 — reusing 전용 발견이 아님).

### 5.5 최종 결론
**mp3gain에서 angora-reusing은 real branch coverage도, 유니크 버그 수도 baseline 대비 단 하나도 더 찾지 못했다.** "더 많은 입력/크래시를 저장했다"는 5.1의 관찰은 사실이지만, 그 전부가 이미 알려진 4개 버그와 이미 알려진 브랜치를 다른 call-context/다른 바이트 값으로 반복 재발견한 것이다 (5.2). 즉 이 타겟에서는 "효과는 있으나 지표에 안 드러난다"가 아니라 **"활동은 늘었지만 성과는 없다"**가 정확한 설명이다.

**방법론 노트**: mut_op 분포나 "새 입력 수" 같은 1차 지표만으로 효과를 판단하면 오도될 수 있음이 확인됐다. 신뢰할 수 있는 검증은 (1) gcov 기반 실제 소스 브랜치 재실행 비교, (2) gdb 기반 크래시 실제 재실행+스택 비교 — 두 가지뿐이며, 이번에 이 방법을 mp3gain에 대해 5-trial 전체로 확립했다.

## 6. 미해결 / 추가 검증 필요 사항

- exiv2·infotocap·flvmeta도 mp3gain과 같은 방식(`tools/coverage_analysis/find_coverage_increasing_inputs.sh` gcov 재실행 + gdb crash triage)으로 "real coverage/버그가 실제로 늘었는지" 검증 필요 — 특히 exiv2는 원인 2(hang 폭증)가 real coverage/버그 발견에도 방해가 되는지 확인 가치 있음.
- flvmeta의 "0/10 도달" 결론은 온라인 로그의 EDGE 추정치(346.23 vs 346.27, 거의 동일)와 오프라인 재실행 기반 정밀 측정 결과가 다소 어긋남 — 측정 방식 차이인지 실제 격차인지 추가 확인 필요.
- 원인 1의 전역 락 병목 가설은 코드 구조상 타당하나 실측 프로파일링은 하지 않음.
- objdump는 오프라인 커버리지 분석이 아직 5/10 run만 완료된 상태 (진행 중).
- angora-reusing의 로그 실시간 통계(`FOUND`, `EXECS` 등)는 5.3의 버그로 신뢰 불가 — 다른 타겟 분석 시에도 디스크 파일 수 기준으로 재검증 필요.
