#!/usr/bin/env python3
"""
cond_analyze.py — `cond_queue.csv` 의 **taint offset 구조** 분석.

state 비율만 필요하면 `condstate.py`를 쓴다. 이 스크립트는 그보다 한 단계 안쪽 —
조건이 어느 **offset**을, **몇 개 세그먼트**로, **어떤 크기 패턴**(`[1,4]` 등)으로
taint 하는지를 본다. reuse 딕셔너리의 `Pattern: [...]`와 같은 축이라
"딕셔너리가 커버할 수 있는 조건 모집단"을 가늠하는 데 쓴다.

USAGE:
  python analysis_tools/cond_analyze.py <root> [옵션]

    <root>          coverage/ · ar/ 를 포함하는 데이터 루트 (예: _skip_onebyte)
                    ar/ 디렉토리를 직접 줘도 된다.
    --fz  A[,B..]   퍼저 필터        (기본: 자동 탐색)
    --tg  A[,B..]   타깃 필터        (기본: 자동 탐색)
    --tr  0,2       trial 필터       (기본: 첫 trial 하나만; --all-trials 로 전부 합산)
    --all-trials    존재하는 trial 전부 합산
    --top N         상위 패턴 N개 (기본 6)
    --json          JSON 출력

주의: Windows 콘솔은 cp949 → `PYTHONUTF8=1 PYTHONIOENCODING=utf-8` 설정 권장.

(구버전은 ROOT/타깃 목록이 하드코딩돼 있어 다른 실험 디렉토리에 쓰면
 "NO cond_queue"만 나왔다. 이제 <root>를 인자로 받고 타깃을 자동 탐색한다.)
"""
import argparse
import csv
import json
import os
import statistics
import sys
from collections import Counter


def merge_segs(offstr):
    """"2-6&6-7&7-8" → 인접 세그먼트 병합 후 [크기...], 최소 begin, 최대 end."""
    offstr = (offstr or "").strip()
    if not offstr:
        return [], None, None
    segs = []
    for part in offstr.split("&"):
        part = part.strip()
        if "-" not in part:
            continue
        a, _, b = part.partition("-")
        try:
            a, b = int(a), int(b)
        except ValueError:
            continue
        segs.append((a, b))
    if not segs:
        return [], None, None
    segs.sort()
    merged = [list(segs[0])]
    for a, b in segs[1:]:
        if a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    sizes = [b - a for a, b in merged]
    return sizes, segs[0][0], max(b for _, b in segs)


def analyze(paths):
    """여러 cond_queue.csv 를 합산 분석."""
    acc = dict(rows=0, tot=0, starts=[], seg_sizes=[], nseg=[],
               patterns=Counter(), states=Counter(), files=0)
    for path in paths:
        with open(path, newline="", encoding="utf-8", errors="replace") as f:
            r = csv.reader(f)
            try:
                header = [h.strip() for h in next(r)]
            except StopIteration:
                continue
            try:
                i_off, i_state = header.index("offsets"), header.index("state")
            except ValueError:
                sys.stderr.write("[cond_analyze] 컬럼 없음(offsets/state): %s\n" % path)
                continue
            acc["files"] += 1
            for row in r:
                if len(row) <= max(i_off, i_state):
                    continue
                acc["rows"] += 1
                acc["states"][row[i_state].strip()] += 1
                sizes, mn, _ = merge_segs(row[i_off])
                if not sizes:
                    continue
                acc["tot"] += 1
                acc["starts"].append(mn)
                acc["nseg"].append(len(sizes))
                acc["seg_sizes"].extend(sizes)
                acc["patterns"][tuple(sizes)] += 1
    return acc


def summarize(d, top_n):
    if d["tot"] == 0:
        return None
    st, ss, ns = sorted(d["starts"]), d["seg_sizes"], d["nseg"]
    pat = d["patterns"]
    total = sum(pat.values())
    reusable = sum(v for v in pat.values() if v >= 5)
    n1 = sum(1 for s in ss if s == 1)
    single_1b = sum(v for p, v in pat.items() if p == (1,))
    return {
        "rows": d["rows"],
        "conds_with_offsets": d["tot"],
        "distinct_patterns": len(pat),
        "conds_in_pattern_ge5": reusable,
        "conds_in_pattern_ge5_pct": round(100.0 * reusable / total, 1),
        "pattern_[1]_only": single_1b,
        "pattern_[1]_only_pct": round(100.0 * single_1b / total, 1),
        "offset_start": {"p10": st[len(st) // 10], "median": int(statistics.median(st)),
                         "p90": st[9 * len(st) // 10], "max": max(st)},
        "segments_per_cond": {"median": int(statistics.median(ns)), "max": max(ns)},
        "seg_size": {"median": int(statistics.median(ss)),
                     "frac_1byte": round(n1 / len(ss), 3)},
        "states": dict(d["states"].most_common()),
        "top_patterns": [{"pattern": list(p), "count": c}
                         for p, c in pat.most_common(top_n)],
    }


def discover(root, want_fz, want_tg, want_tr, all_trials):
    base = root if os.path.basename(os.path.normpath(root)) == "ar" else os.path.join(root, "ar")
    if not os.path.isdir(base):
        sys.exit("[cond_analyze] '%s' 가 없다. <root>는 ar/ 를 포함하는 디렉토리여야 한다." % base)
    out = []
    for fz in sorted(os.listdir(base)):
        if want_fz and fz not in want_fz:
            continue
        if not os.path.isdir(os.path.join(base, fz)):
            continue
        for tg in sorted(os.listdir(os.path.join(base, fz))):
            if want_tg and tg not in want_tg:
                continue
            tgdir = os.path.join(base, fz, tg)
            if not os.path.isdir(tgdir):
                continue
            trials = sorted((t for t in os.listdir(tgdir) if t.isdigit()), key=int)
            if want_tr is not None:
                trials = [t for t in trials if int(t) in want_tr]
            elif not all_trials:
                trials = trials[:1]
            paths = [os.path.join(tgdir, t, "findings", "cond_queue.csv") for t in trials]
            paths = [p for p in paths if os.path.exists(p)]
            out.append((fz, tg, trials, paths))
    return out


def main():
    ap = argparse.ArgumentParser(description="cond_queue.csv 의 taint offset 구조 분석")
    ap.add_argument("root", help="coverage/ · ar/ 를 포함하는 데이터 루트 (ar/ 직접 지정도 가능)")
    ap.add_argument("--fz", default=None, help="퍼저 필터 (쉼표 구분)")
    ap.add_argument("--tg", default=None, help="타깃 필터 (쉼표 구분)")
    ap.add_argument("--tr", default=None, help="trial 필터 (쉼표 구분)")
    ap.add_argument("--all-trials", action="store_true", help="존재하는 trial 전부 합산")
    ap.add_argument("--top", type=int, default=6, help="상위 패턴 개수 (기본 6)")
    ap.add_argument("--json", action="store_true", help="JSON 출력")
    a = ap.parse_args()

    combos = discover(a.root,
                      set(a.fz.split(",")) if a.fz else None,
                      set(a.tg.split(",")) if a.tg else None,
                      set(int(x) for x in a.tr.split(",")) if a.tr else None,
                      a.all_trials)
    if not combos:
        sys.exit("[cond_analyze] 조건에 맞는 (fuzzer, target) 조합이 없다.")

    results = {}
    for fz, tg, trials, paths in combos:
        name = "%s/%s" % (fz, tg)
        if not paths:
            results[name] = {"error": "cond_queue.csv 없음 (trial %s)" % (trials or "-")}
            continue
        s = summarize(analyze(paths), a.top)
        if s is None:
            results[name] = {"error": "offset 있는 조건 0개"}
        else:
            s["trials"] = trials
            results[name] = s

    if a.json:
        print(json.dumps({"root": a.root, "results": results}, indent=2, ensure_ascii=False))
        return

    for name, s in results.items():
        print("\n### %s" % name)
        if "error" in s:
            print("  %s" % s["error"])
            continue
        print("  trials=%s  rows=%d  offset 있는 조건=%d" % (
            ",".join(s["trials"]), s["rows"], s["conds_with_offsets"]))
        print("  distinct_patterns=%d   패턴이 5회 이상 반복된 조건=%d (%.0f%%)   패턴 [1] 단독=%d (%.0f%%)" % (
            s["distinct_patterns"], s["conds_in_pattern_ge5"], s["conds_in_pattern_ge5_pct"],
            s["pattern_[1]_only"], s["pattern_[1]_only_pct"]))
        o = s["offset_start"]
        print("  offset START:  p10=%d  median=%d  p90=%d  max=%d" % (
            o["p10"], o["median"], o["p90"], o["max"]))
        print("  segments/cond: median=%d max=%d    seg SIZE: median=%d frac_1byte=%.2f" % (
            s["segments_per_cond"]["median"], s["segments_per_cond"]["max"],
            s["seg_size"]["median"], s["seg_size"]["frac_1byte"]))
        print("  states: " + ", ".join("%s=%d" % kv for kv in s["states"].items()))
        print("  top patterns: " + ", ".join(
            "%s:%d" % (p["pattern"], p["count"]) for p in s["top_patterns"]))


if __name__ == "__main__":
    main()
