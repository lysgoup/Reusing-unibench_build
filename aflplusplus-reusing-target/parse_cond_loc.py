#!/usr/bin/env python3
"""Parses ANGORA_OUTPUT_COND_LOC=1's raw stderr output (dfsan_legacy's
vendored AngoraPass.cc, unmodified from Angora_original -- see
getInstructionId()'s own errs() calls) into a clean cmpid -> source
location table.

Each instrumented comparison/switch site the pass assigns a cmpid to
emits a 2-3 line block while compiling:
    [ID] <cmpid>
    [INS] <LLVM IR instruction text>
    [LOC] <file>, Ln <line>, Col <col>     (omitted if no debug info)

cmpid is a hash of (line, col, per-module id) with an in-module
uniqueness-dedup pass (see AngoraPass.cc's getInstructionId()), so it is
stable across a rebuild of the exact same source with the exact same
compiler flags, and matches the cmpid embedded in that binary's runtime
.dtaint track files (include/dtaint.h's dtaint_cond_record.cmpid) --
this table is the missing link between the two.

Usage: parse_cond_loc.py raw_stderr.log > cmpid_log.txt
"""
import re
import sys

ID_RE = re.compile(r"^\[ID\] (\d+)$")
INS_RE = re.compile(r"^\[INS\]\s*(.*)$")
LOC_RE = re.compile(r"^\[LOC\] (.*), Ln (\d+), Col (\d+)$")


def parse(lines):
    i, n = 0, len(lines)
    while i < n:
        m = ID_RE.match(lines[i])
        if not m:
            i += 1
            continue

        cid = m.group(1)
        ins = ""
        loc = "NO_DEBUG_INFO"
        j = i + 1

        if j < n:
            mi = INS_RE.match(lines[j])
            if mi:
                ins = mi.group(1).strip()
                j += 1

        if j < n:
            ml = LOC_RE.match(lines[j])
            if ml:
                loc = f"{ml.group(1)}:{ml.group(2)}:{ml.group(3)}"
                j += 1

        yield cid, loc, ins
        i = j


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1]) as f:
        lines = f.read().splitlines()

    print("# cmpid\tsource_location(file:line:col)\tllvm_ir_instruction")
    for cid, loc, ins in parse(lines):
        print(f"{cid}\t{loc}\t{ins}")


if __name__ == "__main__":
    main()
