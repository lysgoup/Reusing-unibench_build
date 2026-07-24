#!/usr/bin/env python3
"""
Analyze whether cmpids grouped under the same Angora "label pattern"
(the shape of critical-byte offset segments) tend to come from the
same source file / same function ("similar logic").

Inputs (resolved automatically from --target/--trial, or overridable):
  cmpid_fast.txt              - cmpid -> file, line, col, insn
  findings/label_patterns.txt - pattern shape -> cmpid records
  --src-root                  - extracted target source tree (for ctags)
"""
import re, sys, os, collections, bisect, json, subprocess, argparse, random

DEFAULT_BASE_DIR = "/home/yunseo/Reusing_mut/Reusing-unibench_build/AR_5_24_M_64b3b/ar/angora-reusing"
DEFAULT_SRC_ROOT = "/home/yunseo/source"
CTAGS_BIN = "ctags"

# ---------- module-level state, populated by load() ----------
cmpid_loc = {}       # cmpid -> (file, line, col, insn)
patterns = []        # list of Pattern
basename_index = {}  # basename -> [fullpaths under SRC_ROOT]
func_ranges_cache = {}  # file -> sorted (by start line) list of (start, end, qualified_name)

Pattern = collections.namedtuple("Pattern", "pid shape size records")


def add_common_args(parser):
    """CLI args shared by every script in this directory: --target/--trial
    (used to auto-locate cmpid_fast.txt and findings/label_patterns.txt
    under --base-dir), or direct --cmpid-fast/--label-pat overrides, plus
    --src-root for the extracted source tree ctags reads from."""
    g = parser.add_argument_group("input location")
    g.add_argument("--target", help="target name, e.g. exiv2, mp3gain, objdump")
    g.add_argument("--trial", help="run/trial number under the target dir, e.g. 0")
    g.add_argument("--base-dir", default=DEFAULT_BASE_DIR,
                    help=f"parent dir containing <target>/<trial>/ (default: {DEFAULT_BASE_DIR})")
    g.add_argument("--cmpid-fast", help="explicit path to cmpid_fast.txt (overrides --target/--trial)")
    g.add_argument("--label-pat", help="explicit path to findings/label_patterns.txt (overrides --target/--trial)")
    g.add_argument("--src-root", default=DEFAULT_SRC_ROOT,
                    help=f"extracted source tree to resolve branches against (default: {DEFAULT_SRC_ROOT})")
    return parser


def resolve_input_paths(args):
    """Turn parsed args into (cmpid_fast_path, label_pat_path), preferring
    explicit --cmpid-fast/--label-pat, else deriving from --target/--trial."""
    if args.cmpid_fast and args.label_pat:
        return args.cmpid_fast, args.label_pat
    if not args.target or not args.trial:
        raise SystemExit("need either (--cmpid-fast and --label-pat) or (--target and --trial)")
    run_dir = os.path.join(args.base_dir, args.target, args.trial)
    cmpid_fast = args.cmpid_fast or os.path.join(run_dir, "cmpid_fast.txt")
    label_pat = args.label_pat or os.path.join(run_dir, "findings", "label_patterns.txt")
    for p in (cmpid_fast, label_pat):
        if not os.path.isfile(p):
            raise SystemExit(f"not found: {p}")
    return cmpid_fast, label_pat


def load(cmpid_fast_path, label_pat_path, src_root):
    """Parse cmpid_fast.txt + label_patterns.txt and index src_root.
    Populates (and returns) the module-level cmpid_loc/patterns/basename_index.
    Safe to call more than once (e.g. to switch targets in one session)."""
    global cmpid_loc, patterns, basename_index, func_ranges_cache
    cmpid_loc = {}
    line_re = re.compile(r'^(-?\d+):\s*(.+?),\s*(\d+),\s*(\d+),\s*\[(\w+)\]\s*$')
    with open(cmpid_fast_path) as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            m = line_re.match(line)
            if not m:
                continue
            cmpid, fname, lno, col, insn = m.groups()
            cmpid_loc[int(cmpid)] = (fname.strip(), int(lno), int(col), insn)
    print(f"[cmpid_fast] parsed {len(cmpid_loc)} cmpid -> location entries", file=sys.stderr)

    patterns = []
    pat_hdr_re = re.compile(r'^Pattern:\s*(\[[^\]]*\])\s*\(size:\s*(\d+)\)')
    rec_re = re.compile(r'^\s*Records:\s*(\d+)')
    cmpid_re = re.compile(r'^\s*Cmpid:\s*(-?\d+)')
    with open(label_pat_path) as f:
        lines = f.readlines()
    i = 0
    pid = 0
    while i < len(lines):
        m = pat_hdr_re.match(lines[i])
        if m:
            shape = m.group(1)
            size = int(m.group(2))
            i += 1
            rm = rec_re.match(lines[i])
            nrec = int(rm.group(1))
            i += 1
            cmpids = []
            for _ in range(nrec):
                cm = cmpid_re.match(lines[i])
                cmpids.append(int(cm.group(1)))
                i += 3  # Cmpid, Offsets, Critical values
            patterns.append(Pattern(pid, shape, size, cmpids))
            pid += 1
        else:
            i += 1
    print(f"[label_patterns] parsed {len(patterns)} patterns, "
          f"{sum(len(p.records) for p in patterns)} records", file=sys.stderr)

    basename_index = {}
    for _root, _dirs, _files in os.walk(src_root):
        for _fn in _files:
            basename_index.setdefault(_fn, []).append(os.path.join(_root, _fn))
    print(f"[src index] indexed {sum(len(v) for v in basename_index.values())} "
          f"files under {src_root}", file=sys.stderr)

    func_ranges_cache = {}
    return cmpid_loc, patterns


# ---------- function-boundary resolution via Universal Ctags ----------
def compute_func_ranges(path):
    try:
        out = subprocess.run(
            [CTAGS_BIN, "--output-format=json", "--fields=+ne", "-n", "-f", "-", path],
            capture_output=True, text=True, timeout=30,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []

    ranges = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            tag = json.loads(line)
        except json.JSONDecodeError:
            continue
        if tag.get("_type") != "tag" or tag.get("kind") != "function":
            continue
        start = tag.get("line")
        end = tag.get("end", start)
        if start is None:
            continue
        scope = tag.get("scope")
        scope_kind = tag.get("scopeKind")
        name = f"{scope}::{tag['name']}" if scope and scope_kind in (
            "class", "struct", "namespace") else tag["name"]
        # scope_id: the enclosing class/struct/namespace, for a coarser
        # "same class/namespace" grouping between file-level and function-level.
        scope_id = scope if scope and scope_kind in ("class", "struct", "namespace") else None
        ranges.append((start, end, name, scope_id))

    ranges.sort()
    return ranges


def _find_range(fpath, lineno):
    if not os.path.isabs(fpath):
        return None
    if fpath not in func_ranges_cache:
        func_ranges_cache[fpath] = compute_func_ranges(fpath)
    ranges = func_ranges_cache[fpath]
    if not ranges:
        return None
    starts = [r[0] for r in ranges]
    idx = bisect.bisect_right(starts, lineno) - 1
    while idx >= 0:
        s, e, name, scope_id = ranges[idx]
        if e >= lineno:
            return (s, e, name, scope_id)
        idx -= 1
    return None


def resolve_function(fpath, lineno):
    """innermost function containing lineno: among all ranges whose
    start <= lineno <= end, pick the one with the latest start (deepest
    nesting), scanning backward from the bisect point."""
    r = _find_range(fpath, lineno)
    return r[2] if r else None


def resolve_scope(fpath, lineno):
    """enclosing class/struct/namespace of the function containing lineno,
    or None if that function isn't itself a member of one (e.g. a plain
    file-scope C function) or if no function resolves at all."""
    r = _find_range(fpath, lineno)
    return r[3] if r else None


def to_local_path(fname):
    """resolve a bare filename (as recorded per-cmpid) to a path in the
    extracted source tree, preferring src/ over samples/tests/etc."""
    cands = basename_index.get(os.path.basename(fname))
    if not cands:
        return None
    if len(cands) == 1:
        return cands[0]
    preferred = [c for c in cands if f"{os.sep}src{os.sep}" in c]
    return (preferred or cands)[0]


# ---------- standalone report: records-level pattern/function concentration ----------
def mean_top_func_frac(groups):
    """size-weighted mean top-1 fraction (large patterns must not be
    swamped by small ones' variance)."""
    total_top = 0
    total_n = 0
    for g in groups:
        c = collections.Counter(g)
        _, top_n = c.most_common(1)[0]
        total_top += top_n
        total_n += len(g)
    return total_top / total_n


def run_report():
    results = []
    for p in patterns:
        if p.size < 2:
            continue  # single-byte patterns are too generic to be interesting
        locs = []
        for cmpid in p.records:
            loc = cmpid_loc.get(cmpid)
            if not loc:
                continue
            fpath, lno, col, insn = loc
            local = to_local_path(fpath)
            func = resolve_function(local, lno) if local else None
            locs.append((fpath, lno, func))
        if not locs:
            continue
        files = collections.Counter(l[0] for l in locs)
        funcs = collections.Counter((l[0], l[2]) for l in locs if l[2])
        top_file, top_file_n = files.most_common(1)[0]
        top_func = funcs.most_common(1)[0] if funcs else (("", None), 0)
        results.append({
            "pid": p.pid, "shape": p.shape, "nrec": len(locs),
            "n_files": len(files), "top_file": top_file,
            "top_file_frac": top_file_n / len(locs),
            "n_funcs_resolved": sum(funcs.values()),
            "n_distinct_funcs": len(funcs),
            "top_func": top_func[0][1], "top_func_n": top_func[1],
            "top_func_frac": (top_func[1] / len(locs)) if locs else 0,
        })

    results.sort(key=lambda r: -r["nrec"])

    print(f"{'pid':>4} {'shape':<16} {'n':>5} {'files':>5} {'topfile%':>8} "
          f"{'func%':>6}  top_func @ top_file")
    for r in results[:40]:
        print(f"{r['pid']:>4} {r['shape']:<16} {r['nrec']:>5} {r['n_files']:>5} "
              f"{r['top_file_frac']*100:7.1f}% {r['top_func_frac']*100:5.1f}%  "
              f"{r['top_func']} @ {os.path.basename(r['top_file'])}")

    random.seed(0)
    pool = []
    for cmpid, (fpath, lno, col, insn) in cmpid_loc.items():
        local = to_local_path(fpath)
        if not local:
            continue
        func = resolve_function(local, lno)
        if func:
            pool.append((fpath, func))

    sizes = [r["nrec"] for r in results]
    print(f"\n[null model] pool of {len(pool)} resolved (file,func) cmpid "
          f"locations across the whole binary", file=sys.stderr)

    observed_mean_simple = sum(r["top_func_frac"] * r["nrec"] for r in results) / sum(r["nrec"] for r in results)

    TRIALS = 20
    null_means = []
    for _ in range(TRIALS):
        random.shuffle(pool)
        i = 0
        groups = []
        for s in sizes:
            if i + s > len(pool):
                break
            groups.append(pool[i:i+s])
            i += s
        null_means.append(mean_top_func_frac(groups))

    null_avg = sum(null_means) / len(null_means)
    print(f"\n=== Null-model comparison ===")
    print(f"Observed mean top-function fraction across {len(results)} patterns "
          f"(size-weighted): {observed_mean_simple*100:.1f}%")
    print(f"Random-shuffle baseline (same group sizes, {TRIALS} trials): "
          f"{null_avg*100:.1f}%  (min {min(null_means)*100:.1f}%, max {max(null_means)*100:.1f}%)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    add_common_args(parser)
    args = parser.parse_args()
    cmpid_fast_path, label_pat_path = resolve_input_paths(args)
    load(cmpid_fast_path, label_pat_path, args.src_root)
    run_report()


if __name__ == "__main__":
    main()
