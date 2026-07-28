#!/usr/bin/env python3
"""
condstate.py — `ar/{fz}/{tg}/{tr}/findings/cond_queue.csv` 의 조건 state 분포 집계.

Angora의 제약 큐는 조건마다 `state` 컬럼을 갖는다:
  Offset      다중 바이트 taint — GD/Det 등 코어 solver + REUSING 대상
  OneByte     taint가 단일 1바이트 — OneByteFuzz가 256값 완전탐색
  OffsetOpt   최적화된 offset 조건
  Unsolvable  포기(예: OneByte 소진 후 to_unsolvable())
  Timeout     시간 초과

`_skip_onebyte` 류 ablation에서 **OneByte 비율**이 reuse 작동 여부를 좌우하므로
(one-byte 지배 타깃은 reuse가 손댈 조건 자체가 없음) 이 비율을 표로 뽑는다.

USAGE:
  python analysis_tools/condstate.py <root> [옵션]

    <root>            coverage/ · ar/ 를 포함하는 데이터 루트 (예: _skip_onebyte)
    --fz  A[,B..]     퍼저 필터            (기본: ar/ 아래 자동 탐색)
    --tg  A[,B..]     타깃 필터            (기본: 자동 탐색)
    --tr  0,2,4       trial 필터           (기본: 존재하는 전부)
    --per-trial       trial별로 한 줄씩 (기본: trial 합산)
    --sort-by NAME    정렬 키 (기본 OneByte; total/Offset/... 도 가능)
    --json            JSON으로 출력
    --csv PATH        CSV 파일로도 저장
    --quiet           누락 파일 경고 숨김

예)
  python analysis_tools/condstate.py _skip_onebyte
  python analysis_tools/condstate.py _skip_onebyte --fz angora-reusing --per-trial
  python analysis_tools/condstate.py _skip_onebyte --json > condstate.json

주의: Windows 콘솔은 cp949 → `PYTHONUTF8=1 PYTHONIOENCODING=utf-8` 설정 권장.
"""
import argparse
import csv
import json
import os
import sys
from collections import Counter, OrderedDict

# 열 순서 고정(없는 state는 뒤에 알파벳순으로 덧붙임)
KNOWN_STATES = ["Offset", "OneByte", "OffsetOpt", "Unsolvable", "Timeout"]


def cond_queue_path(root, fz, tg, tr):
    return os.path.join(root, "ar", fz, tg, str(tr), "findings", "cond_queue.csv")


def discover(root, want_fz, want_tg, want_tr):
    """ar/ 아래를 훑어 (fz, tg, tr) 조합을 찾는다."""
    base = os.path.join(root, "ar")
    if not os.path.isdir(base):
        sys.exit("[condstate] '%s' 가 없다. <root>는 ar/ 를 포함하는 디렉토리여야 한다." % base)
    combos = []
    for fz in sorted(os.listdir(base)):
        if want_fz and fz not in want_fz:
            continue
        fzdir = os.path.join(base, fz)
        if not os.path.isdir(fzdir):
            continue
        for tg in sorted(os.listdir(fzdir)):
            if want_tg and tg not in want_tg:
                continue
            tgdir = os.path.join(fzdir, tg)
            if not os.path.isdir(tgdir):
                continue
            for tr in sorted(os.listdir(tgdir), key=lambda x: (len(x), x)):
                if not tr.isdigit():
                    continue
                if want_tr is not None and int(tr) not in want_tr:
                    continue
                combos.append((fz, tg, int(tr)))
    return combos


def count_states(path):
    """cond_queue.csv → Counter(state). 헤더 컬럼명 앞뒤 공백 허용."""
    counts = Counter()
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        reader = csv.reader(f)
        try:
            header = [h.strip() for h in next(reader)]
        except StopIteration:
            return counts
        try:
            idx = header.index("state")
        except ValueError:
            raise ValueError("'state' 컬럼 없음 (헤더: %s)" % ",".join(header))
        for row in reader:
            if len(row) <= idx:
                continue          # 잘린 줄은 건너뜀
            s = row[idx].strip()
            if s:
                counts[s] += 1
    return counts


def order_states(all_states):
    """KNOWN_STATES 우선, 나머지는 알파벳순."""
    rest = sorted(s for s in all_states if s not in KNOWN_STATES)
    return [s for s in KNOWN_STATES if s in all_states] + rest


def make_row(label_fields, counts, states):
    total = sum(counts.values())
    row = OrderedDict(label_fields)
    row["total"] = total
    for s in states:
        n = counts.get(s, 0)
        row[s] = n
        row[s + "_pct"] = round(100.0 * n / total, 2) if total else 0.0
    # 파생: one-byte 가 아닌 조건 = reuse/코어 solver가 다룰 수 있는 모집단
    nb = total - counts.get("OneByte", 0)
    row["non_OneByte"] = nb
    row["non_OneByte_pct"] = round(100.0 * nb / total, 2) if total else 0.0
    return row


def print_table(rows, states, key_cols):
    if not rows:
        print("[condstate] 집계할 데이터가 없다.")
        return
    widths = {}
    for c in key_cols:
        widths[c] = max(len(c), max(len(str(r[c])) for r in rows))
    head = "  ".join(c.ljust(widths[c]) for c in key_cols)
    head += "  " + "total".rjust(8)
    for s in states:
        head += "  " + ("%s (n / %%)" % s).rjust(20)
    head += "  " + "non-OneByte".rjust(18)
    print(head)
    print("-" * len(head))
    for r in rows:
        line = "  ".join(str(r[c]).ljust(widths[c]) for c in key_cols)
        line += "  " + "{:,}".format(r["total"]).rjust(8)
        for s in states:
            cell = "{:,} ({:5.2f}%)".format(r[s], r[s + "_pct"])
            line += "  " + cell.rjust(20)
        cell = "{:,} ({:5.2f}%)".format(r["non_OneByte"], r["non_OneByte_pct"])
        line += "  " + cell.rjust(18)
        print(line)


def main():
    ap = argparse.ArgumentParser(
        description="cond_queue.csv 의 조건 state 분포와 비율 집계",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root", help="coverage/ · ar/ 를 포함하는 데이터 루트")
    ap.add_argument("--fz", default=None, help="퍼저 필터 (쉼표 구분)")
    ap.add_argument("--tg", default=None, help="타깃 필터 (쉼표 구분)")
    ap.add_argument("--tr", default=None, help="trial 필터 (쉼표 구분, 예 0,2,4)")
    ap.add_argument("--per-trial", action="store_true", help="trial별로 한 줄씩")
    ap.add_argument("--sort-by", default="OneByte", help="정렬 키 (기본 OneByte 비율 내림차순)")
    ap.add_argument("--json", action="store_true", help="JSON 출력")
    ap.add_argument("--csv", default=None, help="CSV로도 저장할 경로")
    ap.add_argument("--quiet", action="store_true", help="누락 파일 경고 숨김")
    a = ap.parse_args()

    want_fz = set(a.fz.split(",")) if a.fz else None
    want_tg = set(a.tg.split(",")) if a.tg else None
    want_tr = set(int(x) for x in a.tr.split(",")) if a.tr else None

    combos = discover(a.root, want_fz, want_tg, want_tr)
    if not combos:
        sys.exit("[condstate] 조건에 맞는 (fuzzer, target, trial) 조합이 없다.")

    per_trial = {}      # (fz,tg,tr) -> Counter
    missing = []
    for fz, tg, tr in combos:
        p = cond_queue_path(a.root, fz, tg, tr)
        if not os.path.exists(p):
            missing.append(p)
            continue
        try:
            per_trial[(fz, tg, tr)] = count_states(p)
        except ValueError as e:
            missing.append("%s (%s)" % (p, e))

    if missing and not a.quiet:
        sys.stderr.write("[condstate] 읽지 못한 파일 %d개:\n" % len(missing))
        for m in missing[:10]:
            sys.stderr.write("    %s\n" % m)
        if len(missing) > 10:
            sys.stderr.write("    ... 외 %d개\n" % (len(missing) - 10))

    if not per_trial:
        sys.exit("[condstate] 읽은 cond_queue.csv 가 하나도 없다.")

    states = order_states({s for c in per_trial.values() for s in c})

    rows = []
    if a.per_trial:
        key_cols = ["fuzzer", "target", "trial"]
        for (fz, tg, tr) in sorted(per_trial):
            rows.append(make_row(
                [("fuzzer", fz), ("target", tg), ("trial", tr)],
                per_trial[(fz, tg, tr)], states))
    else:
        key_cols = ["fuzzer", "target", "trials"]
        agg = {}
        ntr = Counter()
        for (fz, tg, tr), c in per_trial.items():
            agg.setdefault((fz, tg), Counter()).update(c)
            ntr[(fz, tg)] += 1
        for (fz, tg) in sorted(agg):
            rows.append(make_row(
                [("fuzzer", fz), ("target", tg), ("trials", ntr[(fz, tg)])],
                agg[(fz, tg)], states))

    # 정렬: 지정 state 비율 내림차순 (없으면 total 내림차순)
    skey = a.sort_by
    if skey in states:
        rows.sort(key=lambda r: -r[skey + "_pct"])
    elif skey in ("total", "non_OneByte"):
        rows.sort(key=lambda r: -r[skey])

    if a.json:
        print(json.dumps({"root": a.root, "states": states,
                          "per_trial": a.per_trial, "rows": rows},
                         indent=2, ensure_ascii=False))
    else:
        scope = "trial별" if a.per_trial else "trial 합산"
        print("=== cond_queue state 분포 (%s) — root=%s ===" % (scope, a.root))
        print_table(rows, states, key_cols)

    if a.csv:
        with open(a.csv, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
        sys.stderr.write("[condstate] CSV 저장: %s\n" % a.csv)


if __name__ == "__main__":
    main()
