# Label 패턴 -> 소스 로직 분석

가설 검증용 도구: Angora의 conditional statement(cmpid)들이 같은 critical-byte
"label 패턴" 모양(예: `[4, 4, 2]`)을 공유하면, 실제로 같은 함수/비슷한 로직에서
오는가?

## 사전 준비물

- `ctags` (Universal Ctags) 설치되어 `PATH`에 잡혀 있어야 함 — `file:line` ->
  둘러싼 함수 이름을 알아내는 데 사용.
- 분석 대상 소스코드가 디스크에 압축 해제되어 있어야 함 (`SRC_ROOT` 참고).
  exiv2는 `unifuzz/unibench:coverage` 도커 이미지에서 꺼냈음:
  `docker cp <container>:/unibench/exiv2-0.26 /home/yunseo/source/exiv2-0.26`

## 파일 구성

- `analyze_patterns.py` — 핵심 모듈. `cmpid_fast.txt`(cmpid -> 파일/줄/컬럼)와
  `findings/label_patterns.txt`(패턴 모양 -> cmpid 레코드)를 파싱하고, ctags로
  각 cmpid를 둘러싼 함수를 찾은 뒤, 패턴별 집중도 표와 셔플 기반 null-model
  baseline을 출력함. (레코드 단위 — 같은 branch가 여러 입력에서 반복 등장한
  것도 그대로 포함)
- `analyze_distinct.py` — 같은 아이디어지만 패턴별로 **distinct cmpid**만
  먼저 뽑아서 분석. "같은 branch가 여러 번 풀린 것"이 아니라 "패턴 모양이
  같은 서로 다른 branch들"을 보는 거라 더 설득력 있는 버전. 이 스크립트
  결과를 먼저 보는 걸 추천.
- `compare_pattern_functions.py <pid> [<pid> ...]` — 패턴 id(다른 두 스크립트
  출력의 `pid` 컬럼)를 주면, 그 패턴에 속한 모든 distinct 함수의 실제
  소스코드 전체를 뽑아줌 — 눈으로 직접 비슷한지 확인할 때 사용.

세 스크립트 모두 `analyze_patterns`를 모듈로 import하므로, 반드시
`python3 <스크립트>.py` 형태로 실행해야 함 (그래야 Python이 이 디렉토리를
`sys.path`에 자동으로 넣어줌).

## 사용법

세 스크립트 모두 같은 입력 인자를 공유함 (`--target`/`--trial`로 자동 경로
탐색, 또는 `--cmpid-fast`/`--label-pat`로 직접 지정, `--src-root`로 소스
트리 지정):

```bash
cd tools/pattern_analysis

# target/trial만 주면 cmpid_fast.txt / findings/label_patterns.txt 경로를 자동으로 찾음
python3 analyze_patterns.py --target exiv2 --trial 0
python3 analyze_distinct.py --target exiv2 --trial 0          # 권장 (distinct cmpid 기준)
python3 compare_pattern_functions.py --target exiv2 --trial 0 26 35   # 특정 패턴 id들 코드 비교

# 필요하면 소스 트리 위치를 다른 곳으로
python3 analyze_patterns.py --target exiv2 --trial 0 --src-root /home/yunseo/source

# 경로를 직접 지정하고 싶으면 --cmpid-fast / --label-pat로 오버라이드 가능
python3 analyze_patterns.py \
  --cmpid-fast /path/to/cmpid_fast.txt \
  --label-pat  /path/to/findings/label_patterns.txt \
  --src-root   /home/yunseo/source
```

`--target`/`--trial`은 기본적으로
`AR_5_24_M_64b3b/ar/angora-reusing/<target>/<trial>/` 아래에서
`cmpid_fast.txt`와 `findings/label_patterns.txt`를 찾음. 이 base 디렉토리
자체를 바꾸고 싶으면 `--base-dir`로 오버라이드 가능. `--src-root`의 기본값은
`/home/yunseo/source`.

## 다른 run / 타겟으로 분석하고 싶을 때

exiv2 외에 `AR_5_24_M_64b3b/ar/angora-reusing/` 아래 `flvmeta`, `infotocap`,
`mp3gain`, `objdump`, `tiffsplit` 타겟이나 다른 run(`0`~`9`)을 보고 싶으면
`--target`/`--trial`만 바꿔서 실행하면 됨. 해당 타겟 소스가 아직
`--src-root` 아래 안 꺼내져 있으면 exiv2 때와 동일하게 해당 coverage/build
도커 이미지에서 `docker create` + `docker cp`로 꺼낸 뒤 `--src-root`로
그 경로를 넘기면 됨 — `to_local_path()`가 시작 시 `--src-root` 전체를 한
번 훑어서 basename으로 인덱싱해두기 때문에 파일명만 맞으면 자동으로
찾아줌.

## 출력 읽는 법

- `topfile%` / `func%` — 해당 패턴의 branch들 중 가장 많이 겹치는 단일
  파일/함수가 차지하는 비율.
- null-model 부분이 제일 중요한 검증 단계임: 전체 cmpid 풀을 무작위로
  섞어서 관찰된 패턴들과 같은 크기로 재구성했을 때 기대되는 집중도를
  계산함. 관찰치가 이 baseline보다 확실히 높으면, 패턴 모양이 우연이
  아니라 실제로 공유된 로직을 반영한다는 근거가 됨.
- `compare_pattern_functions.py` 출력은 ctags 기준 완전한 이름
  (`Namespace::Class::method`)으로 나오므로, 서로 다른 클래스의 `read()`
  같은 동명 함수가 섞이지 않음 — 패턴 간 비교할 때는 짧은 함수 이름이
  아니라 이 qualified name을 봐야 함.

## 알려진 한계

- 함수 해석은 ctags가 찾은 `kind: function` 태그의 `[line, end]` 범위에
  branch의 줄이 포함되는지로 판단함. 여러 줄에 걸쳐 확장되는 매크로 안의
  branch나 ctags가 잘못 파싱하는 코드는 `None`으로 처리되어 조용히 집계에서
  빠짐 — 출력되는 개수(`n_files`, `#cmpid`)는 이미 해석에 성공한 것만
  반영함.
- `label_patterns.txt`의 "Records"는 같은 cmpid가 여러 입력에서 풀릴 때마다
  한 번씩 반복 등장함 — "풀린 횟수"가 아니라 "서로 다른 branch"가 궁금한
  질문이면 `analyze_patterns.py`가 아니라 `analyze_distinct.py`를 써야 함.
