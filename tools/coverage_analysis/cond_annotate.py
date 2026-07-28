#!/usr/bin/env python3
"""
cond_annotate.py — cond_queue 통합 주석/집계 도구. **한 번 돌리면 다 나온다.**

  python analysis_tools/cond_annotate.py <root>

설계 원칙 — **버전에 안 흔들리게**
  이 저장소(Reusing_mut)는 실험마다 브랜치가 다르고 mutator 디스패치·이름이 바뀐다.
  실측 확인된 것만 해도:
    main          : current_mut_op 단일 대입 (Reusing|OneByte|Det|GD|…)
    reusing_ver2  : reuse 가 버퍼만 개선하면 뒤이어 도는 스테이지를 `Reusing+GD`
                    처럼 합성 이름으로 태깅. one-byte 조건은 state 기준으로 reuse 스킵
    skip_onebyte  : 패턴 `[1]` 을 donor·recipient 양쪽에서 배제
  게다가 7f3ec_AR_10_24_M 데이터의 `Reusing+Det` 는 위 어느 브랜치 HEAD 에도 없다
  (또 다른 리비전). **그래서 이 도구는 fuzzer 의 디스패치 로직을 재현하지 않는다.**
    · mutator 귀속은 오직 `analysis_*.csv` 의 `mut_op`(로그된 사실)만 쓴다.
    · `analysis_*.csv` 가 없으면 관련 컬럼·표를 **아예 만들지 않는다**(추측값 금지).
    · 버전에 따라 달라질 수 있는 재현(패턴 병합)은 **자기검증**하고, 일치율이 낮으면
      경고를 띄운다.
  `mut_op` 어휘는 닫힌 집합으로 검증하지 않는다 — 데이터에 있는 값을 그대로 싣고
  reuse 개입 여부만 `mutop_uses_reuse()`(접두어 검사)로 본다.

생성물 (파일 2종):
  1) 각 trial 의 `findings/cond_queue_annotated.csv` — 원본 12컬럼 +
       행 단위   : `source` `ir_kind` `cond_dir` `fuzz_type` `reuse_pattern` `belong_seed`
       cmpid 단위: `cmpid_side` `cmpid_flipped_by_fuzzer` `cmpid_reuse_pattern`
                   `cmpid_reuse_donor` `cmpid_rows` `cmpid_n_false` `cmpid_n_true`
                   `cmpid_n_done` `cmpid_states` `cmpid_belong_seeds`
                   `cmpid_belong_seed_paths` `cmpid_gcov_arms`
     **`analysis_<thread_id>.csv` 가 있는 trial 에만** 추가:
       행: `belong_mut_op` `belong_parent`   cmpid: `cmpid_belong_mut_op`
  2) `<root>/cond_report.md` — 전 fuzzer×target 총정리(Markdown)
     analysis 가 없으면 §3(mutator 표)은 "생략한다"고만 적힌다.

원본 `cond_queue.csv` 는 절대 덮어쓰지 않는다.

---------------------------------------------------------------------------
버전 무관하게 안전한 근거 (여러 브랜치에서 동일 확인)
---------------------------------------------------------------------------
* `cond_queue.csv` = `depot/dump.rs`. `!cond.base.is_afl()` 필터 → AFL 조건은 없다.
* `condition` = `defs.rs` FALSE_ST=0 / TRUE_ST=1 / DONE_ST=2. op 상수(`COND_MAX_*`)는
  main·reusing_ver2 간 **차이 없음** → `fuzz_type` 은 안전.
* **DONE(2) 이 되는 경로는 둘**: ① `executor.rs` 거리 0 → `mark_as_done()`
  ② `depot.rs` 같은 cond 가 반대 condition 으로 재트랙 → `mark_as_done()`.
  즉 DONE 은 "이 mutator 가 풀었다"가 아니라 **"양쪽 방향이 관측됐다"** 다.
* `mark_as_done()` → `clear()` 로 **offsets 를 비운다** → DONE 행의 97 % 가 offsets
  공백. 패턴 판정은 같은 cmpid 의 남은 행으로 한다.
* `depot::save_input` 은 `cmpid` 를 `trace!` 로만 쓰고 저장하지 않는다 →
  **"조건을 푼 입력 id" 는 산출물에 없다.** 가장 가까운 근사가 cond_queue 의
  `belong`(그 조건이 DONE 될 때 변이 대상이던 부모 시드).
* `analysis_<thread_id>.csv` = `new_input_id,parent_input_id,mut_op,reusing_detail`.
  실측(7f3ec exiv2 16 trial): `new_input_id` 유일(중복 0), queue 파일 존재율 100 %,
  `belong == new_input_id` **정확 조인** 커버리지 2.2 %(나머지 belong 은 초기 코퍼스).
  `belong == parent_input_id` 로 넓히면 12 % 지만 한 부모에 여러 조건·mutator 가
  섞여 부정확 → **쓰지 않는다.**

---------------------------------------------------------------------------
USAGE
---------------------------------------------------------------------------
  python analysis_tools/cond_annotate.py <root>                 # 전체 (기본)
  python analysis_tools/cond_annotate.py <root> --fz angora-reusing --tg jq --tr 0
  python analysis_tools/cond_annotate.py <root> --md out.md      # 리포트 경로 지정
  python analysis_tools/cond_annotate.py <root> --no-gcov        # gcov 대조 생략(빠름)
  python analysis_tools/cond_annotate.py <root> --preview        # 파일 안 쓰고 미리보기
  python analysis_tools/cond_annotate.py <root> --lookup 1086500937,2134597291

주의: Windows 콘솔은 cp949 → `PYTHONUTF8=1 PYTHONIOENCODING=utf-8` 권장.
"""
import argparse
import csv
import glob
import os
import re
import sys
from collections import defaultdict, OrderedDict, Counter

CMP_KINDS = ("ICmp", "FCmp", "Switch", "CmpFn", "Select")
ENTRY_RE = re.compile(r"^(\d+):\s*([^,]+),\s*(\d+),\s*(\d+)(?:\s*,\s*\[(\w+)\])?\s*$")
DIR_NAME = {"0": "false", "1": "true", "2": "done"}
SIDE_ORDER = ("only-true", "only-false", "both", "unknown")
STATE_ORDER = ("Offset", "OneByte", "OffsetOpt", "Unsolvable", "Timeout")

COND_MAX_EXPLORE_OP = 0x4000 - 1
COND_MAX_EXPLOIT_OP = 0x5000 - 1
COND_AFL_OP, COND_FN_OP, COND_LEN_OP = 0x8001, 0x8002, 0x8003


# ── 매핑/유도 ────────────────────────────────────────────────────────────────
def fuzz_type(op):
    if op == COND_AFL_OP:
        return "AFLFuzz"
    if op == COND_LEN_OP:
        return "LenFuzz"
    if op == COND_FN_OP:
        return "CmpFnFuzz"
    if op <= COND_MAX_EXPLORE_OP:
        return "ExploreFuzz"
    if op <= COND_MAX_EXPLOIT_OP:
        return "ExploitFuzz"
    return "OtherFuzz"


def load_cmpid_map(path):
    m = defaultdict(set)
    if not os.path.exists(path):
        return m
    with open(path, encoding="utf-8", errors="replace") as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            g = ENTRY_RE.match(ln)
            if g:
                m[g.group(1)].add((g.group(2), int(g.group(3)), int(g.group(4)), g.group(5) or ""))
    return m


def load_label_patterns(path):
    """
    label_patterns.txt → (패턴 집합, 기여 cmpid 집합). reusing 런에만 존재(없으면 (None,None)).

    **핵심**: `reusing.rs::apply_reusing_mutation` 은
        let pattern = extract_pattern_merged(&handler.cond.offsets);
        map.get(&pattern)
    로 **패턴 모양(merged 세그먼트 크기 리스트)** 을 키로 조회한다. cmpid 로 조회하지 않는다.
      · 패턴 집합  → 그 조건에 reuse 가 **적용될 수 있었나**(recipient)
      · cmpid 집합 → 그 비교문이 딕셔너리에 값을 **기여했나**(donor)
    둘은 다른 질문이다.
    """
    if not os.path.exists(path):
        return None, None
    txt = open(path, encoding="utf-8", errors="replace").read()
    pats = set()
    for g in re.findall(r"^Pattern:\s*\[([0-9,\s]*)\]", txt, re.M):
        pats.add(tuple(int(x) for x in g.split(",") if x.strip()))
    return pats, set(re.findall(r"Cmpid:\s*(\d+)", txt))


def merged_pattern(offstr):
    """
    cond_queue 의 `offsets`("2-6&6-7&7-8") → 병합 후 세그먼트 크기 튜플 (7,).

    `label_pattern_tracker.rs::extract_pattern_merged` = `merge_continuous_segments` 와
    **동일 규칙**으로 구현해야 한다:
      · 정렬하지 않는다 (저장된 순서 그대로 순회)
      · `current.end == next.begin` 인 **정확한 인접**일 때만 병합 (겹침 병합 아님)
    """
    segs = []
    for part in (offstr or "").strip().split("&"):
        part = part.strip()
        if "-" not in part:
            continue
        a, _, b = part.partition("-")
        try:
            segs.append([int(a), int(b)])
        except ValueError:
            pass
    if not segs:
        return ()
    merged = [list(segs[0])]
    for a, b in segs[1:]:
        if merged[-1][1] == a:
            merged[-1][1] = b
        else:
            merged.append([a, b])
    return tuple(b - a for a, b in merged)


def seed_namer(findings_dir):
    """
    `belong` 시드 id를 실제 파일명으로 옮긴다.

    `depot/file.rs::get_file_name`은 `id:%06d`로 저장하지만, Windows로 풀어낸 데이터는
    콜론을 못 쓰기 때문에 `id_%06d`가 된다. 그래서 `findings/queue/`를 실제로 훑어
    어느 쪽인지 확인한다. **디렉토리 목록만 읽고 시드 내용은 읽지 않는다.**

    `queue/`를 슬림 폴더에서 빼버린 경우에는 확인할 방법이 없으므로 실행 중인 OS를
    보고 짐작한다(Windows면 `id_`, 아니면 `id:`). 짐작이라는 사실은 호출부에서
    한 번 알려준다.
    """
    qdir = os.path.join(findings_dir, "queue")
    if os.path.isdir(qdir):
        try:
            for n in os.listdir(qdir):
                if n.startswith("id_"):
                    return lambda i: "queue/id_%06d" % i, True
                if n.startswith("id:"):
                    return lambda i: "queue/id:%06d" % i, True
        except OSError:
            pass
    style = "id_%06d" if os.name == "nt" else "id:%06d"
    return (lambda i: "queue/" + (style % i)), False


def pattern_hit(pattern, pats):
    """
    이 조건의 taint 패턴이 reuse 딕셔너리 키에 있나 — **파일에서 읽은 사실만** 쓴다.

      "exact"    : 패턴이 딕셔너리 키로 그대로 존재
      "combined" : 2세그먼트 이상이고 각 세그먼트의 싱글톤 `[size]` 키가 모두 존재
                   (reusing 이 세그먼트 조합으로 주입할 수 있는 형태)
      "no"       : 둘 다 아님

    ⚠ 이건 "reuse 가 실제로 시도됐다"의 **증거가 아니라 필요조건**이다. 시도 여부·성공
    여부는 빌드마다 로직이 다르므로(같은 저장소 안에서도 main / reusing_ver2 /
    skip_onebyte 가 전부 다르다) 여기서 단정하지 않는다. 실제 귀속은 오직
    `analysis_*.csv` 의 `mut_op` 만 쓴다.
    """
    if not pattern:
        return "?"
    if pattern in pats:
        return "exact"
    if len(pattern) >= 2 and all((x,) in pats for x in pattern):
        return "combined"
    return "no"


# `current_mut_op` 값은 **빌드마다 다르다** — 닫힌 집합으로 검증하지 말 것.
#   main / skip_onebyte : Reusing | OneByte | Det | GD | Random | Cbh | MB |
#                         Exploit | AFL | Len | CmpFn   (단일 대입)
#   reusing_ver2        : 위에 더해 **합성값** `Reusing+Det` · `Reusing+GD`
#                         (7f3ec_AR_10_24_M 데이터가 이 계열)
# 따라서 reuse 개입 판정은 접두어 검사로 한다.
def mutop_uses_reuse(op):
    return "Reusing" in (op or "")


def load_analysis1(findings_dir):
    """
    `analysis_<thread_id>.csv` 전부 → (mut_op Counter, 총행수). 없으면 (None, 0).

    `executor.rs::Drop`: `out_dir.join(format!("analysis_{}.csv", self.cmd.id))` —
    파일명의 숫자는 **스레드 id** 이므로 멀티스레드 런에서는 여러 개가 생긴다.
    (`--analysis_mode` 로 켰을 때만 생성됨.)
    컬럼: `new_input_id,parent_input_id,mut_op,reusing_detail`
    `reusing_detail` 은 `current_mut_op == "Reusing"` 일 때만 채워진다.
    """
    paths = sorted(glob.glob(os.path.join(findings_dir, "analysis_*.csv")))
    if not paths:
        return None, None
    c, byid, byparent = Counter(), {}, defaultdict(set)
    for path in paths:
        with open(path, newline="", encoding="utf-8", errors="replace") as f:
            for row in csv.DictReader(f):
                row = {(k or "").strip(): (v or "").strip() for k, v in row.items()}
                op = row.get("mut_op")
                if not op:
                    continue
                c[op] += 1
                nid = row.get("new_input_id")
                if nid:
                    # new_input_id 는 유일(실측 중복 0) → 정확 1:1 조인 키
                    byid[nid] = (op, row.get("parent_input_id", ""))
                pid = row.get("parent_input_id")
                if pid:
                    # 이 입력이 만들어질 때 변이 대상이던 시드 → 그 시드에 속한 조건을
                    # 대상으로 돌아간 mutator. cmpid 단위는 아니라 dilution 이 있다.
                    byparent[pid].add(op)
    return c, (byid, dict(byparent))


def load_gcov_arms(info_path):
    arms = defaultdict(lambda: [0, 0])
    cur = None
    if not info_path or not os.path.exists(info_path):
        return {}
    for line in open(info_path, errors="replace"):
        if line.startswith("SF:"):
            cur = os.path.basename(line[3:].strip().replace("\\", "/"))
        elif line.startswith("BRDA:") and cur:
            p = line[5:].strip().split(",")
            try:
                key = (cur, int(p[0]))
            except ValueError:
                continue
            arms[key][1] += 1
            if p[-1] not in ("-", "0"):
                arms[key][0] += 1
    return {k: tuple(v) for k, v in arms.items()}


def short_path(p, full):
    if full:
        return p
    p = p.replace("\\", "/").rstrip("/")
    parts = [x for x in p.split("/") if x not in ("", ".", "..")]
    return "/".join(parts[-2:]) if len(parts) >= 2 else (parts[-1] if parts else p)


def render(entries, full_path):
    """set((file,line,col,kind)) → ("jq/jv_dtoa.c:2020", "ICmp")"""
    if not entries:
        return "", ""
    use = [e for e in entries if e[3] in CMP_KINDS] or list(entries)
    byfile = defaultdict(list)
    for fn, line, _col, _k in use:
        byfile[short_path(fn, full_path)].append(line)
    parts = []
    for fn in sorted(byfile):
        lines = sorted(set(byfile[fn]))
        parts.append("%s:%d" % (fn, lines[0]) if len(lines) == 1
                     else "%s:%d-%d" % (fn, lines[0], lines[-1]))
    return " | ".join(parts), ",".join(sorted({e[3] for e in use if e[3]}))


# ── 핵심 처리 ────────────────────────────────────────────────────────────────
def process_trial(d, cmap, lp_pats, lp_cmpids, gcov, full_path, a1=None, a1p=None):
    """cond_queue.csv 한 개 → (rows(list), sides(list), state Counter)."""
    cq = os.path.join(d, "findings", "cond_queue.csv")
    per = defaultdict(lambda: {"0": 0, "1": 0, "2": 0, "states": set(), "rows": 0,
                               "ftypes": set(), "appl": False,
                               "belong_done": set(), "bel_ops": set(), "par_ops": set()})
    namer, namer_sure = seed_namer(os.path.join(d, "findings"))
    states = Counter()
    stat = Counter()          # merge 규칙 자기검증용
    raw, rowinfo = [], []
    with open(cq, newline="", encoding="utf-8", errors="replace") as f:
        r = csv.reader(f)
        header = next(r)
        names = [h.strip() for h in header]
        for col in ("cmpid", "condition", "state", "op", "offsets", "belong"):
            if col not in names:
                raise ValueError("'%s' 컬럼 없음: %s" % (col, cq))
        i_bel = names.index("belong")
        i_c, i_d, i_s, i_op = (names.index("cmpid"), names.index("condition"),
                               names.index("state"), names.index("op"))
        i_off = names.index("offsets")
        for row in r:
            if len(row) > max(i_c, i_d, i_s, i_op, i_off):
                raw.append(row)

    # ── 1차 패스: 행 기본정보 + cmpid 단위 reuse 적용가능성 ────────────────────
    # 주의: `mark_as_done()` 이 `clear()` 로 **offsets 를 비운다**(cond_stmt.rs).
    #       실측상 DONE 행의 97 % 가 offsets 공백 → DONE 행만으로는 패턴을 알 수 없다.
    #       그래서 적용가능성은 같은 cmpid 의 **offsets 가 남은 행**들로 판정한다.
    for row in raw:
        cid, dcond, st = row[i_c].strip(), row[i_d].strip(), row[i_s].strip()
        states[st] += 1
        e = per[cid]
        e["rows"] += 1
        if dcond in e:
            e[dcond] += 1
        e["states"].add(st)
        try:
            op = int(row[i_op].strip())
        except ValueError:
            rowinfo.append(("", "", ""))
            continue
        ft = fuzz_type(op)
        appl = ""
        if lp_pats is not None:
            pat = merged_pattern(row[i_off])
            if not pat:
                appl = "?"          # offsets 비어 있음(대개 DONE) → 행 단위로는 판정 불가
            else:
                # apply_reusing_mutation 은 Explore/Exploit 분기에서만 호출된다
                appl = pattern_hit(pat, lp_pats)
                stat["pat_seen"] += 1
                if appl != "no":
                    stat["pat_hit"] += 1
                    e["appl"] = True
        rowinfo.append((ft, appl))

    # ── 2차 패스: DONE 행의 belong → analysis 정확 조인 ────────────────────────
    for row, (ft, _appl) in zip(raw, rowinfo):
        if row[i_d].strip() != "2" or not ft:
            continue
        e = per[row[i_c].strip()]
        e["ftypes"].add(ft)
        bel = row[i_bel].strip()
        if bel.isdigit():
            e["belong_done"].add(int(bel))
            if a1 is not None and bel in a1:       # 정확 1:1 조인 (new_input_id)
                e["bel_ops"].add(a1[bel][0])
            if a1p is not None and bel in a1p:     # belong 을 부모로 삼아 돌아간 mutator
                e["par_ops"].update(a1p[bel])

    sides = []
    for cid, e in per.items():
        seen = {k for k in ("0", "1") if e[k]}
        flipped = e["2"] > 0
        side = ("both" if (flipped or seen == {"0", "1"})
                else "only-false" if seen == {"0"}
                else "only-true" if seen == {"1"} else "unknown")
        src, kind = render(cmap.get(cid, set()), full_path)
        rec = OrderedDict([
            ("cmpid", cid), ("source", src), ("ir_kind", kind), ("side", side),
            ("flipped_by_fuzzer", "yes" if flipped else "no"),
            ("belong_mut_op", "/".join(sorted(e["bel_ops"]))),
            ("fuzzed_on_belong_mut_op", "/".join(sorted(e["par_ops"]))),
            ("fuzz_type", "/".join(sorted(e["ftypes"])) if flipped else ""),
            # recipient: 이 조건에 reuse 가 적용될 수 있었나(패턴 모양이 딕셔너리에 있나)
            ("reuse_pattern", "" if lp_pats is None else ("yes" if e["appl"] else "no")),
            # donor: 이 비교문이 딕셔너리에 값을 기여했나
            ("reuse_donor", "" if lp_cmpids is None else ("yes" if cid in lp_cmpids else "no")),
            ("rows", e["rows"]), ("n_false", e["0"]), ("n_true", e["1"]), ("n_done", e["2"]),
            ("states", "/".join(sorted(s for s in e["states"] if s))),
            # DONE 행의 belong = 그 조건이 풀릴 때 변이 대상이던 **부모 시드**
            ("belong_seeds", ";".join(str(x) for x in sorted(e["belong_done"])[:5])),
            ("belong_seed_paths", ";".join(namer(x) for x in sorted(e["belong_done"])[:3])),
        ])
        if gcov:
            m = re.match(r"^(.*):(\d+)$", src)
            g = gcov.get((os.path.basename(m.group(1)), int(m.group(2)))) if m else None
            rec["gcov_arms"] = ("%d/%d" % g) if g else ""
        sides.append(rec)
    sides.sort(key=lambda r: (SIDE_ORDER.index(r["side"]) if r["side"] in SIDE_ORDER else 9,
                              r["source"], r["cmpid"]))

    # ── 단일 산출물: 행 단위 + cmpid 단위 정보를 한 CSV에 ────────────────────
    by_cmpid = {r["cmpid"]: r for r in sides}
    CM = ["side", "flipped_by_fuzzer"]
    if a1 is not None:
        CM += ["belong_mut_op", "fuzzed_on_belong_mut_op"]
    CM += ["reuse_pattern", "reuse_donor", "rows", "n_false", "n_true", "n_done",
           "states", "belong_seeds", "belong_seed_paths"]
    if gcov:
        CM.append("gcov_arms")
    out_rows = [list(header)
                + [" source", " ir_kind", " cond_dir", " fuzz_type",
                   " reuse_pattern", " belong_seed"]
                + ([" belong_mut_op", " belong_parent"] if a1 is not None else [])
                + [" cmpid_" + c for c in CM]]
    for row, (ft, appl) in zip(raw, rowinfo):
        cid = row[i_c].strip()
        src, kind = render(cmap.get(cid, set()), full_path)
        s = by_cmpid.get(cid, {})
        out_rows.append(list(row)
                        + [" " + src, " " + kind, " " + DIR_NAME.get(row[i_d].strip(), ""),
                           " " + ft, " " + appl,
                           " " + (namer(int(row[i_bel])) if row[i_bel].strip().isdigit() else "")]
                        + ((lambda h: [" " + (h[0] if h else ""), " " + (h[1] if h else "")])
                           (a1.get(row[i_bel].strip())) if a1 is not None else [])
                        + [" " + str(s.get(c, "")) for c in CM])
    stat["seed_name_guessed"] = 0 if namer_sure else 1
    return out_rows, sides, states, stat


def discover(root, want_fz, want_tg, want_tr):
    base = root if os.path.basename(os.path.normpath(root)) == "ar" else os.path.join(root, "ar")
    if not os.path.isdir(base):
        sys.exit("[cond_annotate] '%s' 가 없다. <root>는 ar/ 를 포함하는 디렉토리여야 한다." % base)
    out = []
    for fz in sorted(os.listdir(base)):
        if (want_fz and fz not in want_fz) or not os.path.isdir(os.path.join(base, fz)):
            continue
        for tg in sorted(os.listdir(os.path.join(base, fz))):
            tgdir = os.path.join(base, fz, tg)
            if (want_tg and tg not in want_tg) or not os.path.isdir(tgdir):
                continue
            for tr in sorted((t for t in os.listdir(tgdir) if t.isdigit()), key=int):
                if want_tr is not None and int(tr) not in want_tr:
                    continue
                out.append((fz, tg, tr, os.path.join(tgdir, tr)))
    return out


# ── Markdown 리포트 ──────────────────────────────────────────────────────────
def md_cell(x):
    """셀 안의 `|` 는 표를 깨뜨리므로 이스케이프."""
    return str(x).replace("|", "\\|")


def md_table(headers, rows):
    out = ["| " + " | ".join(md_cell(h) for h in headers) + " |",
           "|" + "|".join("---" for _ in headers) + "|"]
    for r in rows:
        out.append("| " + " | ".join(md_cell(x) for x in r) + " |")
    return "\n".join(out)


def build_report(root, agg, files, has_a1):
    keys = sorted(agg)
    L = ["# cond_queue 총정리", "",
         "- 데이터 루트: `%s`" % root,
         "- 생성 파일: trial마다 `findings/cond_queue_annotated.csv` (총 %d개). 원본 `cond_queue.csv`는 그대로 둔다." % len(files),
         ""]

    # 1. state 분포
    st_names = [s for s in STATE_ORDER if any(agg[k]["states"].get(s) for k in keys)]
    rows = []
    for k in keys:
        a = agg[k]
        tot = sum(a["states"].values())
        cells = ["{:,} ({:.1f}%)".format(a["states"].get(s, 0),
                                         100.0 * a["states"].get(s, 0) / tot if tot else 0)
                 for s in st_names]
        nb = tot - a["states"].get("OneByte", 0)
        rows.append([k[0], k[1], a["trials"], "{:,}".format(tot)] + cells +
                    ["{:,} ({:.1f}%)".format(nb, 100.0 * nb / tot if tot else 0)])
    L += ["## 1. 조건 state 분포 (trial 합산)", "",
          md_table(["fuzzer", "target", "trials", "total"] + st_names + ["non-OneByte"], rows), "",
          "> `OneByte` 비율이 높을수록 reuse가 손댈 수 있는 조건이 줄어든다. "
          "맨 오른쪽 `non-OneByte`가 reuse와 코어 solver가 함께 노리는 모집단이다.", ""]

    # 2. 분기 방향
    rows = []
    for k in keys:
        a = agg[k]
        n = sum(a["sides"].values())
        rows.append([k[0], k[1], "{:,}".format(n)] +
                    ["{:,} ({:.0f}%)".format(a["sides"].get(s, 0),
                                             100.0 * a["sides"].get(s, 0) / n if n else 0)
                     for s in SIDE_ORDER[:3]])
    L += ["## 2. cmpid별 분기 방향", "",
          md_table(["fuzzer", "target", "cmpid", "only-true", "only-false", "both"], rows), "",
          "> `condition`은 0이 false, 1이 true, 2가 done(퍼저가 반대쪽을 찾아냄)이다. "
          "`only-true`는 그 비교가 늘 참이었다는 뜻이므로 거짓 쪽 분기는 한 번도 "
          "실행되지 않았다는 말이 된다. `both`는 양쪽이 모두 실행된 경우다.", ""]

    # 3. both 해결 mutator — analysis_*.csv 가 있을 때만 (없으면 추측값이라 생략)
    if has_a1:
        allm = sorted({m for k in keys for m in agg[k]["solved"]},
                      key=lambda m: -sum(agg[k]["solved"].get(m, 0) for k in keys))
        rows = []
        for k in keys:
            a = agg[k]
            tot = sum(a["solved"].values())
            rows.append([k[0], k[1], "{:,}".format(tot)] +
                        ["{:,}".format(a["solved"].get(m, 0)) if a["solved"].get(m) else "·"
                         for m in allm])
        L += ["## 3. `both` cmpid와 이어지는 mutator", "",
              md_table(["fuzzer", "target", "solved"] + allm, rows), "",
          "> 이 표는 `belong == new_input_id` 조인이다. `executor.rs`에서 새 입력을 저장하며 "
          "받은 `id`가 곧바로 `analysis`의 `new_input_id`가 되고, 같은 `id`로 track을 돌려 "
          "나온 조건들의 `belong`에 그대로 박힌다(`fparser.rs`의 `cond.base.belong = id`). "
          "그래서 이 조인은 id가 같은지 보는 것이라 어긋날 여지가 없다.",
          "> 다만 뜻은 **\"이 조건이 발견된 입력을 만든 mutator\"**다. 조건을 푼 mutator가 "
          "아니다. 퍼저가 어느 mutator가 어느 cmpid를 뒤집었는지 기록하지 않기 때문에 "
          "그 값은 산출물 어디에도 없다.",
          "> `fuzzed_on_belong_mut_op` 컬럼은 반대편 조인(`belong == parent_input_id`)이다. "
          "그 시드를 부모로 삼아 돌아간 mutator라서 방향은 더 가깝지만, 한 시드에 여러 조건이 "
          "매달려 있으면 섞인다. 두 값을 같이 보는 편이 낫다.", ""]
    else:
        L += ["## 3. `both` cmpid의 부모 시드를 만든 mutator", "",
              "`analysis_*.csv`가 없어서 이 표는 만들지 않았다. `op`와 `state`로 역산할 수는 "
              "있지만 그건 로그가 아니라 추측이라 넣지 않는다. §5를 참고하면 된다.", ""]

    # 4. cmpid 를 누가 열었나 (angora / reusing / both)
    fzs = sorted({k[0] for k in keys})
    tgs = sorted({k[1] for k in keys})
    base_fz = "angora" if "angora" in fzs else fzs[0]
    if len(fzs) >= 2:
        L += ["## 4. cmpid를 누가 열었나", "",
              "비교문 하나하나를 **어느 로직 덕분에 열렸나** 기준으로 셋으로 나눈다.", "",
              "| 분류 | 뜻 | 판정 |",
              "|---|---|---|",
              "| **angora** | baseline(`%s`)만 커버했다. reusing 빌드는 놓쳤다. |" % base_fz
              + " baseline 쪽 집합에만 있음 |",
              "| **reusing** | reusing 빌드만 커버했고, 그 조건의 taint 패턴이 딕셔너리에 "
              "있어서 reuse가 손댈 수 있었다. **reuse 로직 덕분일 후보다.** |"
              " reusing 쪽에만 있고 `reuse_pattern`이 `exact` 또는 `combined` |",
              "| **both (angora 로직)** | reuse 없이도 열리는 것들이다. 양쪽 다 커버했거나, "
              "reusing 빌드에만 있더라도 패턴이 딕셔너리에 없어 reuse가 개입할 수 없었다. |"
              " 양쪽 교집합 + reusing 단독 중 `reuse_pattern=no` |", "",
              "`both`에 reusing 단독분이 섞이는 이유는, 그것도 결국 코어 mutator가 찾은 것이라 "
              "성격이 교집합과 같기 때문이다. 실행 순서나 예산 차이로 baseline이 그 조건을 "
              "못 봤을 뿐이다.", "",
              "기준은 두 가지다. **도달**은 taint가 걸린 채 실행돼 cond_queue에 올라온 것, "
              "**both 해결**은 양쪽 분기가 모두 실행된 것을 뜻한다. 수치는 trial 합집합 기준이다.", ""]
        for field, title in (("seen", "4.1 cond_queue에 올라온 cmpid"),
                             ("both", "4.2 양쪽 분기가 모두 실행된 cmpid")):
            rows, details = [], []
            for tg in tgs:
                sets = {fz: set(agg[(fz, tg)][field]) for fz in fzs if (fz, tg) in agg}
                if len(sets) < 2:
                    continue
                shared = set.intersection(*sets.values())
                nA = nR = nB = 0
                for fz in fzs:
                    excl = sets[fz] - set().union(*[sets[o] for o in sets if o != fz])
                    for cid in sorted(excl, key=lambda c: (-len(agg[(fz, tg)][field][c]), c)):
                        appl = agg[(fz, tg)]["appl"].get(cid, "")
                        if fz == base_fz:
                            cls, nA = "angora", nA + 1
                        elif appl == "yes":
                            cls, nR = "reusing", nR + 1
                        else:
                            cls, nB = "both (angora 로직)", nB + 1
                        bel = sorted(agg[(fz, tg)]["bel"].get(cid, set()),
                                     key=lambda x: int(x) if x.isdigit() else 0)[:3]
                        details.append((tg, fz, cls, cid, agg[(fz, tg)]["src"].get(cid, ""),
                                        agg[(fz, tg)]["solv"].get(cid, ""),
                                        len(agg[(fz, tg)][field][cid]),
                                        agg[(fz, tg)]["trials"], ",".join(bel)))
                rows.append([tg, "{:,}".format(nA), "{:,}".format(nR),
                             "{:,}".format(len(shared) + nB)])
            L += ["### %s" % title, "",
                  md_table(["target", "angora", "reusing", "both (angora 로직)"], rows), ""]
            if details:
                order = {"angora": 0, "reusing": 1, "both (angora 로직)": 2}
                details.sort(key=lambda d: (order[d[2]], d[0], -d[6]))
                shown = details[:45]
                L += [md_table(["분류", "target", "cmpid", "source", "belong_mut_op",
                                "belong 시드 id", "등장 trial", "전체"],
                               [[d[2], d[0], "`%s`" % d[3], "`%s`" % d[4], d[5] or "-",
                                 ("`%s`" % d[8]) if d[8] else "-",
                                 d[6], d[7]] for d in shown]), "",
                      "> 이 표에는 **한쪽 빌드에만 나온 cmpid**만 싣는다. `both`로 분류된 것 중 "
                      "교집합에 해당하는 것들은 수가 많아 표에서 뺐고, 개수만 위 표에 적었다.",
                      "> `belong`은 그 조건이 DONE 처리될 때 변이 대상이던 부모 시드다"
                      "(`findings/queue/id_XXXXXX`). `depot.rs::save_input`이 cmpid를 로그로만 "
                      "흘리고 저장하지 않기 때문에 **조건을 푼 입력 자체의 id는 산출물에 없다**. "
                      "`belong`이 그나마 가장 가까운 값이다.", ""]
                if len(details) > len(shown):
                    L += ["> 전체 %d개 중 앞 %d개만 실었다(angora→reusing→both 순, 등장 trial 많은 순). "
                          "나머지는 각 trial의 `cond_queue_annotated.csv`에서 `cmpid`로 찾으면 된다."
                          % (len(details), len(shown)), ""]
                L += ["> 등장 trial 수가 전체의 1~2회에 그치면 trial 간 편차로 보는 게 맞다. "
                      "능력 차이로 읽으려면 대부분의 trial에서 재현돼야 한다.", ""]
            else:
                L += ["> 한쪽만 커버한 cmpid가 없다.", ""]

    # 6. analysis_1.csv 실측
    if has_a1:
        allops = sorted({o for k in keys for o in agg[k]["mutop"]},
                        key=lambda o: -sum(agg[k]["mutop"].get(o, 0) for k in keys))
        rows = []
        for k in keys:
            a = agg[k]
            if not a["mutop"]:
                continue
            rows.append([k[0], k[1], "{:,}".format(sum(a["mutop"].values()))] +
                        ["{:,}".format(a["mutop"].get(o, 0)) if a["mutop"].get(o) else "·"
                         for o in allops])
        share = []
        for k in keys:
            m = agg[k]["mutop"]
            t = sum(m.values())
            if t:
                r = sum(v for o, v in m.items() if mutop_uses_reuse(o))
                share.append([k[0], k[1], "{:,}".format(t), "{:,}".format(r),
                              "{:.1f}%".format(100.0 * r / t)])
        L += ["## 5. `analysis_*.csv`에 기록된 `mut_op` 분포", "",
              md_table(["fuzzer", "target", "inputs"] + allops, rows), "",
              "reuse가 만들어낸 입력의 비중이다. `mut_op`에 `Reusing`이 들어간 행을 센다.", "",
              md_table(["fuzzer", "target", "inputs", "reuse 생성", "비중"], share), "",
              "> 입력을 실제로 만들어낸 스테이지이고, 퍼저가 직접 남긴 로그다. 이 보고서에서 "
              "mutator에 관해 가장 믿을 만한 수치다. 다만 `mut_op` 이름은 빌드마다 달라서 "
              "미리 정해둔 목록으로 걸러내지 않고 파일에 있는 값을 그대로 싣는다. "
              "입력 단위 집계라 cmpid와 직접 이어지지는 않는다. cmpid별로 보려면 §3을 참고하면 된다.", ""]
    else:
        L += ["## 5. `analysis_*.csv`", "",
              "이 데이터셋에는 없다. 그래서 mutator를 귀속하는 컬럼"
              "(`belong_mut_op`, `belong_parent`, `cmpid_belong_mut_op`)과 §3 표를 아예 만들지 "
              "않았다. 추측으로 채우느니 비워두는 편이 낫다고 봤다. 퍼징할 때 "
              "`--analysis_mode`를 켜면 `analysis_<thread_id>.csv`가 생기고, 그때부터 위 컬럼과 "
              "§3·§5가 채워진다.", ""]

    L += ["## 6. `cond_queue_annotated.csv` 컬럼 설명", "",
          md_table(["컬럼", "단위", "설명"], [
              ["원본 12컬럼", "행", "`cond_queue.csv`에서 그대로 가져온 값. `cmpid, context, order, belong, p, op, condition, arg1, arg2, is_desirable, offsets, state`"],
              ["`source`", "cmpid", "소스 위치. `cmpid_track.txt`에서 가져온 `파일:라인`"],
              ["`ir_kind`", "cmpid", "LLVM IR 종류. ICmp, Switch, CmpFn 등"],
              ["`cond_dir`", "행", "이 행의 `condition`을 읽기 쉽게 옮긴 값. `false`, `true`, `done`"],
              ["`fuzz_type`", "행", "`op`에서 결정되는 퍼징 종류. ExploreFuzz, ExploitFuzz, LenFuzz, CmpFnFuzz"],

              ["`cmpid_side`", "cmpid", "그 비교문이 한쪽만 탔는지 양쪽 다 탔는지. `only-true`, `only-false`, `both`"],
              ["`cmpid_flipped_by_fuzzer`", "cmpid", "`condition==2`인 행이 있는지. 있으면 퍼저가 반대쪽을 찾아낸 것"],
              ["`belong_mut_op`, `belong_parent`", "행", "`belong == new_input_id` 조인. 이 조건이 **발견된 입력**을 만든 `mut_op`과 그 부모다. 같은 `id`를 보는 것이라 어긋나지 않지만, 조건을 푼 mutator는 아니다"],
              ["`cmpid_fuzzed_on_belong_mut_op`", "cmpid", "`belong == parent_input_id` 조인. 그 시드를 **부모로 삼아 돌아간** mutator다. 방향은 더 가깝지만 한 시드에 조건이 여럿이면 섞인다"],
              ["`cmpid_belong_mut_op`", "cmpid", "그 cmpid의 DONE 행들이 가리키는 `belong` 시드를 모두 이어 붙여 얻은 `mut_op` 모음"],
              ["`reuse_pattern`", "행", "이 행의 taint 패턴이 reuse 딕셔너리 키에 있는지. `exact`는 패턴이 그대로 있는 경우, `combined`는 세그먼트별 단일 패턴이 모두 있는 경우, `?`는 `offsets`가 비어 판단할 수 없는 경우다. reuse가 주입하려면 갖춰야 할 조건일 뿐, 실제로 시도했거나 성공했다는 뜻은 아니다"],
              ["`cmpid_reuse_pattern`", "cmpid", "그 cmpid의 행 중 `offsets`가 남아 있는 것들만 놓고 봤을 때 하나라도 딕셔너리에 걸리는지"],
              ["`cmpid_reuse_donor`", "cmpid", "그 비교문이 딕셔너리에 값을 넣어준 쪽인지. `label_patterns.txt`의 `Cmpid:` 항목에 있으면 yes다. 위 `reuse_pattern`이 받는 쪽이라면 이건 주는 쪽이다"],
              ["`cmpid_rows`, `n_false`, `n_true`, `n_done`", "cmpid", "`cmpid_side`를 판정할 때 근거가 된 행 수"],
              ["`cmpid_states`", "cmpid", "그 cmpid가 거쳐 간 state 모음"],
              ["`cmpid_gcov_arms`", "cmpid", "같은 소스 라인에서 gcov가 실제로 덮은 분기 수와 전체 분기 수. `--no-gcov`면 생기지 않는다"],
          ]), "",
          "## 7. 읽을 때 주의할 점", "",
          "- 여기 나오는 분류는 어디까지나 Angora가 taint로 추적한 범위 안의 이야기다. "
          "taint가 걸리지 않은 실행은 cond_queue에 남지 않기 때문에, gcov 기준으로는 양쪽 분기가 "
          "모두 실행됐는데도 여기서는 한쪽만 탄 것으로 보일 수 있다. jq에서 재본 결과 "
          "`both`는 gcov 2/2 팔이 118/121(97.5%)로 잘 맞았지만, 한쪽만 탄 경우는 gcov 1/2 팔이 "
          "33/45(73%)에 그쳤다. `gcov_arms` 컬럼으로 직접 대조해 보는 게 좋다.",
          ""]
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(
        description="cond_queue 주석 + cmpid 분기방향/해결 mutator + Markdown 총정리")
    ap.add_argument("root", help="coverage/ · ar/ 를 포함하는 데이터 루트 (ar/ 직접 지정도 가능)")
    ap.add_argument("--fz", default=None, help="퍼저 필터 (쉼표 구분)")
    ap.add_argument("--tg", default=None, help="타깃 필터 (쉼표 구분)")
    ap.add_argument("--tr", default=None, help="trial 필터 (쉼표 구분)")
    ap.add_argument("--md", default=None, help="Markdown 리포트 경로 (기본 <root>/cond_report.md)")
    ap.add_argument("--no-gcov", action="store_true", help="gcov_arms 대조 생략(빠름)")
    ap.add_argument("--full-path", action="store_true", help="소스 경로를 자르지 않음")
    ap.add_argument("--preview", action="store_true", help="파일 안 쓰고 앞부분만 화면에")
    ap.add_argument("--limit", type=int, default=15, help="--preview 행 수")
    ap.add_argument("--lookup", default=None, help="cmpid 조회만 (쉼표 구분)")
    a = ap.parse_args()

    combos = discover(a.root,
                      set(a.fz.split(",")) if a.fz else None,
                      set(a.tg.split(",")) if a.tg else None,
                      set(int(x) for x in a.tr.split(",")) if a.tr else None)
    if not combos:
        sys.exit("[cond_annotate] 조건에 맞는 (fuzzer, target, trial) 조합이 없다.")

    if a.lookup:
        for fz, tg, tr, d in combos:
            cmap = load_cmpid_map(os.path.join(d, "cmpid_track.txt"))
            print("### %s/%s/%s (cmpid_track %d개)" % (fz, tg, tr, len(cmap)))
            for cid in a.lookup.split(","):
                src, kind = render(cmap.get(cid.strip(), set()), a.full_path)
                print("  %-12s %-44s %s" % (cid.strip(), src or "<매핑 없음>", kind))
        return

    agg = defaultdict(lambda: {"states": Counter(), "sides": Counter(), "solved": Counter(),
                               "mutop": Counter(), "reuse": Counter(), "trials": 0,
                               "seen": defaultdict(set), "both": defaultdict(set),
                               "src": {}, "appl": {}, "solv": {}, "bel": {}})
    files, has_a1, warned_seedname = [], False, False

    for fz, tg, tr, d in combos:
        cq = os.path.join(d, "findings", "cond_queue.csv")
        if not os.path.exists(cq):
            sys.stderr.write("[cond_annotate] cond_queue.csv 없음: %s\n" % cq)
            continue
        cmap = load_cmpid_map(os.path.join(d, "cmpid_track.txt"))
        lp_pats, lp_cmpids = load_label_patterns(os.path.join(d, "findings", "label_patterns.txt"))
        # `coverage_final.info`가 없는 데이터셋도 있어서 `coverage.info`로 넘어간다.
        # 실측상 둘은 같은 파일이다(63f576 tiffsplit에서 라인키 2,788개 완전 일치).
        gcov = {}
        if not a.no_gcov:
            covdir = os.path.join(a.root, "coverage", fz, tg, tr)
            for name in ("coverage_final.info", "coverage.info"):
                gcov = load_gcov_arms(os.path.join(covdir, name))
                if gcov:
                    break
        mutop, a1 = load_analysis1(os.path.join(d, "findings"))
        a1_by_parent = a1[1] if a1 else None
        a1 = a1[0] if a1 else None
        if mutop:
            has_a1 = True
        try:
            rows, sides, states, stat = process_trial(d, cmap, lp_pats, lp_cmpids, gcov,
                                                     a.full_path, a1, a1_by_parent)
        except (ValueError, StopIteration) as e:
            sys.stderr.write("[cond_annotate] %s\n" % e)
            continue

        if stat.get("seed_name_guessed") and not warned_seedname:
            warned_seedname = True
            sys.stderr.write(
                "[cond_annotate] 참고: findings/queue/가 없어 시드 파일명 형식을 "
                "확인하지 못했다. belong_seed 컬럼은 '%s' 형식으로 짐작해 적는다.\n"
                % ("id_NNNNNN" if os.name == "nt" else "id:NNNNNN"))

        if stat["pat_seen"] and lp_pats is not None:
            rate = 100.0 * stat["pat_hit"] / stat["pat_seen"]
            if rate < 20.0:
                sys.stderr.write(
                    "[cond_annotate] 경고: %s/%s/%s 패턴 일치율 %.1f%% — 이 빌드의 "
                    "세그먼트 병합 규칙이 다를 수 있다. reuse_pattern 컬럼을 "
                    "신뢰하지 말 것.\n" % (fz, tg, tr, rate))

        k = (fz, tg)
        A = agg[k]
        A["trials"] += 1
        A["states"] += states
        for s in sides:
            A["sides"][s["side"]] += 1
            cid = s["cmpid"]
            A["seen"][cid].add(tr)
            A["src"].setdefault(cid, s["source"])
            if s.get("reuse_pattern") == "yes":
                A["appl"][cid] = "yes"
            A["appl"].setdefault(cid, s.get("reuse_pattern", ""))
            if s.get("belong_mut_op"):
                A["solv"][cid] = s["belong_mut_op"]
            if s.get("belong_seeds"):
                A["bel"].setdefault(cid, set()).update(s["belong_seeds"].split(";"))
            if s["side"] == "both":
                A["both"][cid].add(tr)
                # 귀속은 analysis_*.csv 의 실측 mut_op 만 (유도값 없음)
                for m in (s.get("belong_mut_op", "").split("/") if s.get("belong_mut_op") else []):
                    A["solved"][m] += 1

        if mutop:
            A["mutop"] += mutop

        if a.preview:
            print("\n### %s/%s/%s  (cond_queue_annotated 앞 %d행)" % (fz, tg, tr, a.limit))
            w = csv.writer(sys.stdout, lineterminator="\n")
            for r in rows[:a.limit + 1]:
                w.writerow(r)
            continue

        p1 = os.path.join(d, "findings", "cond_queue_annotated.csv")
        with open(p1, "w", newline="", encoding="utf-8") as f:
            csv.writer(f, lineterminator="\n").writerows(rows)
        files.append(p1)
        print("%-15s %-10s t%-2s  rows=%-7d cmpid=%-5d  a1=%s  → %s" % (
            fz, tg, tr, len(rows) - 1, len(sides),
            ("%d행" % sum(mutop.values())) if mutop else "없음", p1))

    if a.preview or not agg:
        return
    md_path = a.md or os.path.join(a.root, "cond_report.md")
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(build_report(a.root, agg, files, has_a1))
    print("\n[cond_annotate] CSV %d개 + 리포트 → %s" % (len(files), md_path))


if __name__ == "__main__":
    main()
