# captainrc templates

Purpose-named starting points for `run.sh` campaign configs. Copy one next to
the scripts and fill in the machine-specific paths:

    cp captainrc.examples/saturation_experiment captainrc_myrun
    vi captainrc_myrun          # fill every /path/to/... placeholder
    ./run.sh captainrc_myrun

Live configs (`tools/captainrc*`) are gitignored on purpose: they are full of
machine-local paths and core allocations that rot the moment they leave the
server they were written on. Only these templates are tracked. Past per-server
configs survive in git history (removed from tracking 2026-10; `git log --all
-- tools/captainrc*` finds them).

## Which template

| Template | When |
|---|---|
| `baseline` | Ordinary fixed-length campaign: fuzzers run for `TIMEOUT`, live coverage or post-hoc measurement. |
| `saturation_gen` | Generate a saturated corpus: long run whose final queue becomes the seed for later experiments (`SATURATION_GEN=1`). |
| `saturation_experiment` | Fuzz **from** a saturated corpus (`SATURATION_MODE=1`); campaign length is enforced by `archive_campaigns.sh`, not `TIMEOUT`. |
| `reusing` | Any reusing-arm fuzzer (`aflplusplus-reusing`, `forkserver_libafl_reusing`): same as the others plus the mandatory `TAINT_DIR`. |

## Knob reference

Everything `run.sh`/`start.sh` read from a captainrc (sourced with `set -a`,
so every assignment is exported). `<target>` keys: hyphens become underscores
(`gdk-pixbuf-pixdata` -> `gdk_pixbuf_pixdata_SEED`).

| Variable | Required | Meaning |
|---|---|---|
| `WORKDIR` | yes | Where `ar/ cache/ coverage/ log/ poc/ lock/` land. Reusing an existing WORKDIR appends: trial ids continue after the highest existing one. |
| `REPEAT` | yes | Trials per (fuzzer, target). |
| `FUZZERS` | yes | Array of fuzzer names (= `tools/volume/<fuzzer>/` and image tag `unifuzz/unibench:<fuzzer>`). `run.sh` re-runs `build.sh` for each; an already-built image is a fast cache no-op. |
| `<fuzzer>_TARGETS` / `TARGETS` | yes | Targets per fuzzer (bare `TARGETS` covers every fuzzer). Names from `tools/volume/targets.conf`. |
| `WORKER_POOL` | no | Space-separated CPU ids. Unset: every CPU. One campaign holds `CAMPAIGN_WORKERS` (default 1) cores until it **ends** — with no `TIMEOUT`, a pool smaller than fuzzers x targets x REPEAT splits the run into waves, and only something that kills campaigns (e.g. `archive_campaigns.sh`) lets the next wave start. |
| `TIMEOUT` | no | Campaign length (`timeout(1)` syntax, e.g. `24h`). Unset: campaigns run until killed — only sensible together with `archive_campaigns.sh`. |
| `<target>_SEED` / `<target>_SEEDS` | no | Seed dir, mounted read-only as `/customized_seed` (the fuzzer's volume run.sh prefers it when non-empty). `_SEEDS=(s0 s1 ...)` gives trial i its own seed dir. Unset: the image-internal corpus. |
| `SATURATION_MODE` | no | `1`: install each campaign's seed corpus as its `iter_0000.tar.gz` baseline and have `archive_queue.sh` treat the dry-run queue as base, archiving only post-start deltas. Without it a saturated-seed run's first snapshot swallows the whole dry-run queue. |
| `<target>_BASE` / `<target>_BASES` | no | Override where that `iter_0000` base comes from when it is not simply the seed dir (e.g. a `base.tar.gz` from a `SATURATION_GEN` run). Default: `SEED`. |
| `SATURATION_GEN` | no | `1`: after each campaign ends, tar its final queue to `ar/.../base.tar.gz` for later experiments to reuse as their base. |
| `<target>_TAINT_DIR` / `TAINT_DIR` | reusing only | Host dir with `value_pool.dict` / `unsolved_condition` / `*.dtaint` from `taint_scan`, mounted read-only at `/taint`. `run.sh` refuses to start a reusing fuzzer without it (and the dir must exist). |
| `GLOBAL_FUZZARGS` / `<fuzzer>_FUZZARGS` | no | Extra args appended to the fuzzer command line (e.g. `--analysis-mode` for angora arms). |
| `DRYRUN` | no | `1`: stop each campaign right after seed import (`dryrun_finish`). Smoke test, not an experiment. |
| `CAMPAIGN_WORKERS` / `<fuzzer>_CAMPAIGN_WORKERS` | no | Cores per campaign (default 1). |
| `<fuzzer>_DISABLE_TRIM` / `DEFAULT_DISABLE_TRIM` | no | Export `AFL_DISABLE_TRIM` in-container (AFL++ arms; LibAFL arms ignore it). |
| `<target>_QUEUE_FILE` | no | Mount a `cond_queue.csv` read-only at `/restore` (angora restore runs). |
| `POLL` | no | run.sh status-poll seconds (default 5). |

## Pairing with archive_campaigns.sh

For any config without `TIMEOUT`, start the archiver (ideally first — it
idles until campaigns appear, and attaching late skews the first snapshot
window):

    screen -dmS archiver bash -c \
      './archive_campaigns.sh <WORKDIR> <INTERVAL_MIN> <MAX_ITERATIONS>; exec bash'
    ./run.sh captainrc_myrun

Campaign length = INTERVAL x MAX_ITERATIONS minutes (e.g. 15 x 96 = 24h).
Caveat: the driver self-terminates once every campaign it can see finished
archiving — if the run is split into waves, restart it (or loop it) for the
next wave. Details: `tools/SCRIPTS.md`.
