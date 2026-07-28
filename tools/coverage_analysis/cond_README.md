# cond_queue 분석 도구

Angora / angora-reusing 실험 결과에서 `cond_queue.csv`를 읽어 소스 위치·분기 방향·
mutator 귀속을 붙이고, fuzzer×target 총정리 리포트를 뽑는다.

세 개 중 **`cond_annotate.py` 하나만 돌리면 대부분 끝난다.** 나머지 둘은 특정 축만
빠르게 볼 때 쓰는 보조 도구다.

```
python coverage/cond_annotate.py <데이터루트>
```

Windows 콘솔은 기본 인코딩이 cp949라 한글 출력이 깨진다. 앞에 환경변수를 붙인다.

```
PYTHONUTF8=1 PYTHONIOENCODING=utf-8 python coverage/cond_annotate.py <데이터루트>
```

---

## 1. 필요한 데이터

`<데이터루트>` 아래 `ar/`와 `coverage/`만 있으면 된다. `log/`, `chart_stat.json`,
`cmpid_fast.txt`, `crashes/`, `hangs/`, `graph/`는 하나도 읽지 않는다.

```
<데이터루트>/
├─ ar/{fuzzer}/{target}/{trial}/
│    ├─ cmpid_track.txt
│    └─ findings/
│         ├─ cond_queue.csv        ← 이것만 필수
│         ├─ label_patterns.txt    (reusing 런에만 존재)
│         ├─ analysis_*.csv        (--analysis_mode로 퍼징했을 때만)
│         └─ queue/                (파일 하나만 남겨둬도 충분)
└─ coverage/{fuzzer}/{target}/{trial}/coverage_final.info   (없으면 coverage.info)
```

| 파일 | 없으면 |
|---|---|
| `cond_queue.csv` | 그 trial을 통째로 건너뛴다 |
| `cmpid_track.txt` | `source`·`ir_kind`가 빈칸이 된다 |
| `label_patterns.txt` | `reuse_pattern`·`reuse_donor`가 빈칸이 된다 |
| `analysis_*.csv` | mutator 귀속 컬럼과 리포트 §3을 **아예 만들지 않는다** |
| `coverage_final.info` | `cmpid_gcov_arms`가 빈칸이 된다 (`--no-gcov`와 같음) |
| `queue/` | 시드 파일명 형식을 못 알아내 OS를 보고 짐작하고, 그 사실을 알려준다 |

`queue/`는 **디렉토리 목록만 읽고 시드 내용은 읽지 않는다.** 파일명이 `id:000081`
(리눅스 원본)인지 `id_000081`(Windows로 푼 것)인지 확인하는 용도가 전부다.

`ar/`를 루트로 바로 줘도 동작한다. 이때는 `coverage/`를 못 찾으니 gcov 대조가 빠진다.

실측으로 확인한 것: 위 6개 파일만 남긴 최소 트리(18파일, 60MB)와 원본 전체 트리
(10만 파일)의 출력이 **한 행도 다르지 않다.**

---

## 2. 산출물

### `ar/{fz}/{tg}/{tr}/findings/cond_queue_annotated.csv`

원본 `cond_queue.csv`는 건드리지 않고 옆에 새로 쓴다. 원본 12컬럼에 아래가 붙는다.

| 컬럼 | 단위 | 설명 |
|---|---|---|
| `source` | cmpid | 소스 위치. `cmpid_track.txt`에서 가져온 `파일:라인` |
| `ir_kind` | cmpid | LLVM IR 종류. ICmp, Switch, CmpFn 등 |
| `cond_dir` | 행 | 이 행의 `condition`. `false`, `true`, `done` |
| `fuzz_type` | 행 | `op`에서 결정되는 퍼징 종류 |
| `reuse_pattern` | 행 | taint 패턴이 reuse 딕셔너리에 있는지. `exact` / `combined` / `no` / `?` |
| `belong_seed` | 행 | `belong` 시드 파일 경로 |
| `cmpid_side` | cmpid | `only-true` / `only-false` / `both` |
| `cmpid_flipped_by_fuzzer` | cmpid | `condition==2`인 행이 있는지 |
| `cmpid_rows`, `n_false`, `n_true`, `n_done` | cmpid | `cmpid_side` 판정 근거가 된 행 수 |
| `cmpid_states` | cmpid | 그 cmpid가 거쳐 간 state 모음 |
| `cmpid_reuse_pattern`, `cmpid_reuse_donor` | cmpid | 받는 쪽 / 주는 쪽 |
| `cmpid_belong_seeds`, `cmpid_belong_seed_paths` | cmpid | DONE 행들의 `belong` 시드 |
| `cmpid_gcov_arms` | cmpid | 같은 소스 라인에서 gcov가 덮은 분기 수 / 전체 |

`analysis_*.csv`가 있는 trial에만 추가된다.

| 컬럼 | 단위 | 설명 |
|---|---|---|
| `belong_mut_op`, `belong_parent` | 행 | `belong == new_input_id` 조인 |
| `cmpid_belong_mut_op` | cmpid | 위를 cmpid 단위로 모은 것 |
| `cmpid_fuzzed_on_belong_mut_op` | cmpid | `belong == parent_input_id` 조인 |

### cmpid ↔ mut_op ↔ input_id를 어떻게 잇는가

퍼저는 **어느 mutator가 어느 cmpid를 뒤집었는지 기록하지 않는다.** `depot::save_input`이
`cmpid`를 인자로 받긴 하지만 `trace!` 로그로만 흘리고 파일에도 `analysis_*.csv`에도
남기지 않는다. 그래서 cmpid → mutator 직결은 **원리상 불가능**하고, 시드 id를 다리로
삼아 두 방향으로 우회한다.

`executor.rs`의 흐름이 근거다.

```rust
let id = self.depot.save(status, &buf, cmpid);                  // 새 입력 id
self.analysis_entries.push((id, current_parent_input, current_mut_op, ...));
                        //   └ new_input_id   └ parent_input_id  └ mut_op
let cond_stmts = self.track(id, buf, speed);                    // 같은 id로 track
  → load_track_data(..., id, ...)
  → cond.base.belong = id                                       // fparser.rs
```

같은 `id` 하나가 `analysis.new_input_id`와 `cond.belong` 양쪽에 그대로 박힌다.
그리고 `current_parent_input`은 `fuzz_loop.rs`에서 `cond.base.belong`을 그대로 받는다.
여기서 두 갈래가 나온다.

| 조인 | 뜻 | 성격 |
|---|---|---|
| `belong == new_input_id` | 이 조건이 **발견된 입력**을 만든 mutator | id 동일성 검사라 어긋날 여지가 없다. 대신 조건을 푼 mutator가 아니라 한 단계 앞이다 |
| `belong == parent_input_id` | 그 시드를 **부모로 삼아 돌아간** mutator | 방향은 더 가깝다. 대신 한 시드에 조건이 여럿 매달리면 섞인다 |

63f576 exiv2 t0(angora-reusing) 실측:

- DONE 14,782행 기준 cmpid 단위 채움률은 각각 **69.9%**와 **83.6%**
- 둘 다 채워진 10,257행 중 **93%**가 값이 겹친다
- 행 단위로는 3.2% / 11.2%로 훨씬 낮다. cmpid 하나에 DONE 행이 여럿이라 하나만 걸려도 채워지기 때문이다
- 희석 정도: `belong` 하나에 매달린 DONE 조건 수는 중앙값 2, 최대 169. 서로 다른 cmpid 수로는 중앙값 1, 최대 42
- `parent` 쪽 조인이 가리키는 `mut_op` 종류는 중앙값 1종(1,481행), 2종 이상은 174행뿐

**두 컬럼을 같이 보는 게 맞다.** 어느 쪽도 "이 mutator가 이 조건을 풀었다"의 증거는
아니다. 그 값이 정말 필요하면 퍼저 쪽에서 `analysis_entries.push`에 `cmpid`를 한 칸
더 넣으면 되고, 그때부터 완전한 cmpid → mutator 매핑이 생긴다. 기존 데이터에는
소급되지 않는다.

`belong`이 항상 최초 발견 입력인 것도 아니다. `depot.rs`의 `PREFER_FAST_COND`가 켜져
있으면 더 빠른 입력이 들어올 때 `mem::swap`으로 저장된 cond를 통째로 갈아치우므로
`belong`도 같이 바뀐다.

### `<데이터루트>/cond_report.md`

fuzzer×target 총정리 7개 절. ①state 분포 ②cmpid별 분기 방향 ③`both` cmpid와 이어지는
mutator ④cmpid를 누가 열었나 ⑤`analysis_*.csv` mut_op 분포 ⑥컬럼 설명 ⑦읽을 때 주의할 점.

§4는 비교문을 셋으로 나눈다.

| 분류 | 판정 |
|---|---|
| **angora** | baseline 쪽 집합에만 있다 |
| **reusing** | reusing 쪽에만 있고 `reuse_pattern`이 `exact` 또는 `combined`다. reuse가 손댈 수 있었으니 reuse 로직 덕분일 후보다 |
| **both (angora 로직)** | 양쪽 교집합, 그리고 reusing 단독이지만 `reuse_pattern=no`라 reuse가 개입할 수 없었던 것. 둘 다 reuse 없이 열린 것들이라 한 칸에 묶고, 표에는 몫을 나눠 적는다 |

`reusing`으로 분류됐다고 reuse가 그 조건을 풀었다는 증거는 아니다. 패턴이 딕셔너리에
있었다는 필요조건까지만 확인한 것이다.

---

## 3. 설계 원칙 — 퍼저 로직을 재현하지 않는다

`Reusing_mut` 저장소는 실험마다 브랜치가 다르고 mutator 디스패치와 이름이 바뀐다.

| 브랜치 | 다른 점 |
|---|---|
| `main` | `current_mut_op` 단일 대입 (`Reusing`, `OneByte`, `Det`, `GD` …) |
| `reusing_ver2` | reuse가 버퍼만 개선하면 뒤이어 도는 스테이지를 `Reusing+GD`처럼 합성 이름으로 태깅. one-byte 조건은 `state` 기준으로 reuse를 건너뜀 |
| `skip_onebyte` | 패턴 `[1]`을 pool 기록과 주입 양쪽에서 배제 |

게다가 `7f3ec_AR_10_24_M` 데이터의 `Reusing+Det`은 위 어느 브랜치 HEAD에도 없다.
또 다른 리비전이라는 뜻이다. 그래서 이 도구는 다음을 지킨다.

- mutator 귀속은 `analysis_*.csv`의 `mut_op`, 즉 **퍼저가 직접 남긴 로그만** 쓴다.
- `analysis_*.csv`가 없으면 관련 컬럼과 표를 **아예 만들지 않는다.** 추측으로 채우지 않는다.
- `mut_op` 어휘를 미리 정한 목록으로 검증하지 않는다. 파일에 있는 값을 그대로 싣고,
  reuse 개입 여부만 이름에 `Reusing`이 들어갔는지로 판단한다.
- 버전에 따라 달라질 수 있는 재현(세그먼트 병합 규칙)은 **자기검증**한다. 패턴 일치율이
  20% 아래로 떨어지면 경고를 띄우고 그 컬럼을 믿지 말라고 알린다.

### 버전과 무관하게 확인된 사실

- `cond_queue.csv`는 `depot/dump.rs`가 쓰고 `!cond.base.is_afl()` 필터가 있어 AFL 조건은 안 실린다.
- `condition`은 `defs.rs`의 FALSE_ST=0 / TRUE_ST=1 / DONE_ST=2다. op 상수는 main과
  reusing_ver2 사이에 차이가 없어서 `fuzz_type` 계산은 안전하다.
- DONE(2)이 되는 경로는 둘이다. `executor.rs`에서 거리가 0이 될 때와, `depot.rs`에서
  같은 cond가 반대 `condition`으로 다시 트랙될 때. 그래서 DONE은 "이 mutator가 풀었다"가
  아니라 **"양쪽 방향이 관측됐다"**에 가깝다.
- `mark_as_done()`이 `clear()`로 `offsets`를 비운다. DONE 행의 97%가 `offsets` 공백이라
  패턴 판정은 같은 cmpid의 남은 행으로 한다.
- `depot::save_input`은 `cmpid`를 로그로만 흘리고 저장하지 않는다. 그래서 **조건을 푼 입력
  자체의 id는 산출물에 없다.** `belong`이 그나마 가장 가까운 값이다.

---

## 4. 옵션

```
--fz / --tg / --tr    퍼저·타깃·trial 필터 (쉼표 구분)
--md PATH             리포트 경로 지정 (기본 <데이터루트>/cond_report.md)
--no-gcov             gcov 대조 생략. 빨라진다
--preview             파일 안 쓰고 앞부분만 화면에
--lookup ID,ID        cmpid만 조회하고 끝낸다
--full-path           소스 경로를 자르지 않는다
```

---

## 5. 보조 도구

### `condstate.py` — state 비율만 빠르게

```
python coverage/condstate.py <데이터루트> [--per-trial] [--json] [--csv out.csv]
```

`cond_queue.csv`의 `state` 분포를 n과 %로 뽑는다. `OneByte` 비율이 reuse 작동 여부를
좌우하므로 분석을 시작할 때 제일 먼저 돌려보면 좋다. 파생 컬럼 `non-OneByte`가
reuse와 코어 solver가 함께 노리는 모집단이다.

### `cond_analyze.py` — taint offset 구조

```
python coverage/cond_analyze.py <데이터루트> [--all-trials] [--top N] [--json]
```

state보다 한 단계 안쪽을 본다. 조건이 어느 offset을 몇 개 세그먼트로, 어떤 크기 패턴
(`[4,2]` 등)으로 taint하는지 집계한다. reuse 딕셔너리의 `Pattern:`과 같은 축이라
딕셔너리가 커버할 수 있는 조건 모집단을 가늠할 때 쓴다.

---

## 6. 검증 기록

| 데이터셋 | 결과 |
|---|---|
| `7f3ec_AR_10_24_M` | exiv2 2 fuzzer × 10 trial = 20 CSV. `mut_op`에 `Reusing+Det`·`Reusing+GD` 합성값 |
| `63f576_AR_5T_1D_M` | exiv2·jq·tiffsplit × 2 fuzzer × 5 trial = 30 CSV. `mut_op`은 단일값(`Reusing`, `Det` 포함). jq는 `coverage/`가 없어 gcov만 빠지고 나머지는 정상 |
| 최소 트리 | 필수 6종 파일만 남긴 18파일 트리와 원본 10만 파일 트리의 출력이 완전히 동일 |
| `analysis_*.csv` 없는 트리 | mutator 컬럼 5개와 §3 표가 빠지고 나머지는 정상 |

`analysis_*.csv` 조인 품질(7f3ec exiv2 16 trial 실측):

- `new_input_id`는 유일하다(중복 0). 정확한 1:1 조인 키로 쓸 수 있다.
- `new_input_id`와 `parent_input_id` 모두 queue 파일 존재율 100%.
- `belong == new_input_id` 정확 조인은 DONE 행의 2.2%에 걸린다. 나머지 `belong`은 초기
  코퍼스 시드라 `analysis`에 애초에 없다.
- `belong == parent_input_id`로 넓히면 12%까지 오르지만 한 부모에 여러 조건과 mutator가
  섞여 부정확해서 쓰지 않는다.

taint 추적 범위의 한계(jq 실측, 라인당 cmpid 1개·BRDA 2팔인 부분집합):
`both`는 gcov 2/2 팔이 118/121(97.5%)로 잘 맞지만, 한쪽만 탄 경우는 gcov 1/2 팔이
33/45(73%)에 그친다. taint가 걸리지 않은 실행은 `cond_queue`에 남지 않기 때문이다.
`cmpid_gcov_arms` 컬럼으로 직접 대조해 보는 게 좋다.
