#!/usr/bin/env python3
"""
Same hypothesis test as analyze_patterns.py, but de-duplicated: for each
label pattern, look only at the *distinct* cmpids (distinct conditional
statements) that ever produced that pattern, not raw records (which
repeat a cmpid once per solved input). This isolates the real question:
do *different* branches that share a label-pattern shape tend to sit in
the same file / same class-or-namespace / same function, more than chance
would predict?

Reports three separate concentration metrics per pattern, coarsest to
finest:
  - file%:  fraction of that pattern's distinct branches in the single
    most common source file
  - class%: fraction in the single most common enclosing class/struct/
    namespace (via ctags scope) - a step finer than file, coarser than
    function; branches in free functions with no enclosing scope don't
    count towards this population
  - func%:  fraction in the single most common function (finest signal)
Each has its own null-model baseline, since the three resolve for
different-sized populations of branches.
"""
import argparse, collections, random
import analyze_patterns as ap  # reuses parsing + function-resolution machinery


def null_baseline(pool, sizes, trials, seed=0):
    """shuffle pool and re-partition into groups of `sizes`, return the
    size-weighted mean top-1 concentration across `trials` shuffles."""
    rng = random.Random(seed)
    means = []
    for _ in range(trials):
        rng.shuffle(pool)
        i = 0
        total_top = total_n = 0
        for s in sizes:
            if i + s > len(pool):
                break
            g = pool[i:i+s]
            i += s
            c = collections.Counter(g)
            _, top_n = c.most_common(1)[0]
            total_top += top_n
            total_n += len(g)
        if total_n:
            means.append(total_top / total_n)
    return means


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    ap.add_common_args(parser)
    parser.add_argument("-v", "--verbose", action="store_true",
                         help="for each pattern, list the full file/class/"
                              "function breakdown (all distinct values with "
                              "their counts), not just the top one")
    args = parser.parse_args()
    cmpid_fast_path, label_pat_path = ap.resolve_input_paths(args)
    ap.load(cmpid_fast_path, label_pat_path, args.src_root)

    # ---- per-pattern: distinct cmpids -> resolved file / (file,class) / (file,func) ----
    pattern_info = []
    for p in ap.patterns:
        if p.size < 2:
            continue
        distinct_cmpids = sorted(set(p.records))
        files = []         # every branch that resolved to a source file
        file_classes = []  # subset also resolved to an enclosing class/namespace
        file_funcs = []    # subset also resolved to a function
        for cmpid in distinct_cmpids:
            loc = ap.cmpid_loc.get(cmpid)
            if not loc:
                continue
            fpath, lno, col, insn = loc
            local = ap.to_local_path(fpath)
            if not local:
                continue
            files.append(fpath)
            scope = ap.resolve_scope(local, lno)
            if scope:
                file_classes.append((fpath, scope))
            func = ap.resolve_function(local, lno)
            if func:
                file_funcs.append((fpath, func))
        if len(files) < 2:
            continue  # need at least 2 distinct resolvable branches to say anything
        pattern_info.append((p, files, file_classes, file_funcs))

    print(f"{len(pattern_info)} patterns have >=2 distinct resolvable branches\n")

    rows = []
    for p, files, file_classes, file_funcs in pattern_info:
        fc = collections.Counter(files)
        top_file, top_file_n = fc.most_common(1)[0]
        file_frac = top_file_n / len(files)

        if file_classes:
            clc = collections.Counter(file_classes)
            (class_file, top_class), top_class_n = clc.most_common(1)[0]
            class_frac = top_class_n / len(file_classes)
        else:
            clc, class_file, top_class, class_frac = collections.Counter(), None, None, 0.0

        if file_funcs:
            fnc = collections.Counter(file_funcs)
            (func_file, top_func), top_func_n = fnc.most_common(1)[0]
            func_frac = top_func_n / len(file_funcs)
        else:
            fnc, func_file, top_func, func_frac = collections.Counter(), None, None, 0.0

        rows.append({
            "p": p, "n_file": len(files), "file_frac": file_frac, "top_file": top_file, "file_counter": fc,
            "n_class": len(file_classes), "class_frac": class_frac, "top_class": top_class,
            "class_file": class_file, "class_counter": clc,
            "n_func": len(file_funcs), "func_frac": func_frac, "top_func": top_func,
            "func_file": func_file, "func_counter": fnc,
        })

    rows.sort(key=lambda r: -r["n_file"])

    def trunc(s, w):
        return s if len(s) <= w else s[:w - 1] + "…"

    SHAPE_W = min(24, max((len(r["p"].shape) for r in rows[:40]), default=8))
    FILE_W = min(30, max((len(r["top_file"]) for r in rows[:40]), default=8))
    CLASS_W = min(30, max((len(r["top_class"] or "-") for r in rows[:40]), default=8))

    print(f"{'pid':>4} {'shape':<{SHAPE_W}} {'#file':>6} {'file%':>6}  {'top_file':<{FILE_W}}  |  "
          f"{'#class':>6} {'class%':>6}  {'top_class':<{CLASS_W}}  |  "
          f"{'#func':>6} {'func%':>6}  top_func @ its_file")
    for r in rows[:40]:
        class_str = trunc(r["top_class"] or "-", CLASS_W)
        func_str = f"{r['top_func']} @ {r['func_file']}" if r["top_func"] else "-"
        print(f"{r['p'].pid:>4} {trunc(r['p'].shape, SHAPE_W):<{SHAPE_W}} {r['n_file']:>6} {r['file_frac']*100:5.1f}%  "
              f"{trunc(r['top_file'], FILE_W):<{FILE_W}}  |  "
              f"{r['n_class']:>6} {r['class_frac']*100:5.1f}%  {class_str:<{CLASS_W}}  |  "
              f"{r['n_func']:>6} {r['func_frac']*100:5.1f}%  {func_str}")

        if args.verbose:
            print(f"      file breakdown ({r['n_file']} distinct branches):")
            for f, n in r["file_counter"].most_common():
                print(f"        {n:>4}  ({n / r['n_file'] * 100:5.1f}%)  {f}")
            print(f"      class/namespace breakdown ({r['n_class']} distinct branches with a resolved scope):")
            for (f, cl), n in r["class_counter"].most_common():
                print(f"        {n:>4}  ({n / r['n_class'] * 100:5.1f}%)  {cl} @ {f}")
            print(f"      func breakdown ({r['n_func']} distinct branches with a resolved function):")
            for (f, fn), n in r["func_counter"].most_common():
                print(f"        {n:>4}  ({n / r['n_func'] * 100:5.1f}%)  {fn} @ {f}")
            print()

    # ---- null baselines, one pool per metric (dedup across ALL patterns) ----
    file_pool = []
    class_pool = []
    func_pool = []
    seen = set()
    for p in ap.patterns:
        for cmpid in p.records:
            if cmpid in seen:
                continue
            seen.add(cmpid)
            loc = ap.cmpid_loc.get(cmpid)
            if not loc:
                continue
            fpath, lno, col, insn = loc
            local = ap.to_local_path(fpath)
            if not local:
                continue
            file_pool.append(fpath)
            scope = ap.resolve_scope(local, lno)
            if scope:
                class_pool.append((fpath, scope))
            func = ap.resolve_function(local, lno)
            if func:
                func_pool.append((fpath, func))

    file_sizes = [r["n_file"] for r in rows]
    class_sizes = [r["n_class"] for r in rows if r["n_class"] >= 2]
    func_sizes = [r["n_func"] for r in rows if r["n_func"] >= 2]

    observed_file = sum(r["file_frac"] * r["n_file"] for r in rows) / sum(file_sizes)
    observed_class = (sum(r["class_frac"] * r["n_class"] for r in rows if r["n_class"] >= 2)
                       / sum(class_sizes)) if class_sizes else 0.0
    observed_func = (sum(r["func_frac"] * r["n_func"] for r in rows if r["n_func"] >= 2)
                      / sum(func_sizes)) if func_sizes else 0.0

    TRIALS = 30
    null_file = null_baseline(file_pool, file_sizes, TRIALS)
    null_class = null_baseline(class_pool, class_sizes, TRIALS)
    null_func = null_baseline(func_pool, func_sizes, TRIALS)

    def report(name, pool, observed, null_vals):
        print(f"{name} pool size: {len(pool)}")
        print(f"  Observed size-weighted top-1 fraction: {observed*100:5.1f}%")
        if not null_vals:
            print(f"  Random-shuffle baseline: n/a (empty pool - nothing resolves at this level)")
            return
        print(f"  Random-shuffle baseline ({TRIALS} trials):    "
              f"{sum(null_vals)/len(null_vals)*100:5.1f}%  "
              f"(min {min(null_vals)*100:.1f}%, max {max(null_vals)*100:.1f}%)")

    print(f"\n=== Null-model comparison (DISTINCT cmpids only) ===")
    report("File-level", file_pool, observed_file, null_file)
    report("Class/namespace-level", class_pool, observed_class, null_class)
    report("Function-level", func_pool, observed_func, null_func)


if __name__ == "__main__":
    main()
