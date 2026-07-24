#!/usr/bin/env python3
"""
For a given label-pattern id, print the full source of every *distinct*
function that contains a branch (cmpid) belonging to that pattern, so you
can eyeball whether functions that share a pattern shape but are NOT the
same function still share similar logic.

Usage: python3 compare_pattern_functions.py --target exiv2 --trial 0 <pid> [pid2 ...]
"""
import argparse, collections
import analyze_patterns as ap


def func_source(fpath, func_name, lineno):
    local = ap.to_local_path(fpath)
    if not local:
        return f"    <source not found for {fpath}>"
    ranges = ap.func_ranges_cache.get(local) or ap.compute_func_ranges(local)
    ap.func_ranges_cache[local] = ranges
    # find the range matching this func name and containing lineno
    match = None
    for s, e, name, scope_id in ranges:
        if name == func_name and s <= lineno <= e:
            match = (s, e)
            break
    if not match:
        # fallback: just show a window around the branch line
        s, e = max(1, lineno - 8), lineno + 8
    else:
        s, e = match
    with open(local, errors='replace') as f:
        lines = f.readlines()
    out = []
    for i in range(s, min(e, len(lines)) + 1):
        marker = ">>" if i == lineno else "  "
        out.append(f"  {marker}{i:>5}: {lines[i-1].rstrip()}")
    return "\n".join(out)


def show_pattern(pid):
    p = [pp for pp in ap.patterns if pp.pid == pid]
    if not p:
        print(f"no pattern with pid={pid}")
        return
    p = p[0]
    distinct_cmpids = sorted(set(p.records))
    by_func = collections.OrderedDict()  # (file,func) -> list of (cmpid, lineno)
    for cmpid in distinct_cmpids:
        loc = ap.cmpid_loc.get(cmpid)
        if not loc:
            continue
        fpath, lno, col, insn = loc
        local = ap.to_local_path(fpath)
        func = ap.resolve_function(local, lno) if local else None
        if not func:
            continue
        by_func.setdefault((fpath, func), []).append((cmpid, lno))

    print(f"\n########## Pattern {p.shape} (pid={p.pid}): "
          f"{len(distinct_cmpids)} distinct branches -> {len(by_func)} distinct functions ##########")
    for (fpath, func), occ in sorted(by_func.items(), key=lambda kv: -len(kv[1])):
        cmpid0, lineno0 = occ[0]
        print(f"\n--- {func}()  @ {fpath}   [{len(occ)} branch(es) in this pattern, "
              f"e.g. line {lineno0}] ---")
        print(func_source(fpath, func, lineno0))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    ap.add_common_args(parser)
    parser.add_argument("pids", nargs="+", type=int, help="pattern id(s) to inspect")
    args = parser.parse_args()
    cmpid_fast_path, label_pat_path = ap.resolve_input_paths(args)
    ap.load(cmpid_fast_path, label_pat_path, args.src_root)

    for pid in args.pids:
        show_pattern(pid)


if __name__ == "__main__":
    main()
