#!/usr/bin/env bash
#
# drcov_measure.sh  --  UniBench drcov coverage runner (host-side driver)
# ============================================================================
# 로컬 호스트에서 실행한다. 바이너리와 DynamoRIO 는 도커 컨테이너 안에 있고,
# seeds 와 targets.conf 는 호스트에 있다.
#
#   1) target 이름을 인자로 받아 targets.conf 에서 args/seed_dir/stdin 여부 조회
#   2) 컨테이너 안에서 /d/p/cov/<target> 의 ELF class(32/64bit) 판별
#   3) 해당 bit 의 drrun 으로 drcov 측정 (IDA Lighthouse 용)
#   4) 로그를 [target]_[seedname].log 로 rename 하여 호스트 출력 디렉토리에 저장
#
# Usage:
#   ./drcov_measure.sh <target> [options]
#
# Options:
#   -c, --conf FILE        targets.conf 경로            (default: ./targets.conf)
#   -s, --seeds-root DIR   seed 루트 (하위의 <seed_dir> 를 자동으로 붙임)
#                                                       (default: ./seeds)
#       --seed PATH        seed 파일 또는 디렉토리를 직접 지정
#                          (seed_dir 매핑 무시. --seed-dir 은 같은 뜻의 별칭)
#   -o, --out DIR          호스트 출력 디렉토리         (default: ./drcov_logs)
#   -i, --image NAME       도커 이미지 (docker run 모드)(default: unibench-cov)
#   -C, --container NAME   실행 중인 컨테이너 (docker exec 모드)
#   -T, --timeout SEC      타겟 1회 실행 타임아웃       (default: 60)
#   -l, --list             targets.conf 의 타겟 목록 출력 후 종료
#   -n, --dry-run          실행할 docker 명령만 출력
#   -h, --help             도움말
#
# 예시:
#   ./drcov_measure.sh exiv2 -s ~/unibench_seeds -o ./logs -i unibench-cov
#   ./drcov_measure.sh sqlite3 -C my_running_container
#   # Angora queue 의 단일 seed 하나만:
#   ./drcov_measure.sh exiv2 --seed .../findings/queue/id:001758 -C 0b7ccbdde0ca
#   # queue 디렉토리 전체:
#   ./drcov_measure.sh exiv2 --seed .../findings/queue -C 0b7ccbdde0ca
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 기본값
# ---------------------------------------------------------------------------
CONF="../volume/targets.conf"
SEEDS_ROOT="./seeds"
SEED_PATH=""            # --seed / --seed-dir : 파일 또는 디렉토리
OUTDIR="./drcov_logs"
IMAGE="drcov"
CONTAINER=""
RUN_TIMEOUT=60
DRY_RUN=0
DO_LIST=0
TARGET=""

COV_DIR="/d/p/cov"          # 컨테이너 내 바이너리 위치 (Dockerfile 기준)

die() { echo "[!] $*" >&2; exit 1; }
log() { echo "[*] $*" >&2; }

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ---------------------------------------------------------------------------
# 인자 파싱
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--conf)        CONF="$2"; shift 2 ;;
        -s|--seeds-root)  SEEDS_ROOT="$2"; shift 2 ;;
        --seed|--seed-dir) SEED_PATH="$2"; shift 2 ;;
        -o|--out)         OUTDIR="$2"; shift 2 ;;
        -i|--image)       IMAGE="$2"; shift 2 ;;
        -C|--container)   CONTAINER="$2"; shift 2 ;;
        -T|--timeout)     RUN_TIMEOUT="$2"; shift 2 ;;
        -l|--list)        DO_LIST=1; shift ;;
        -n|--dry-run)     DRY_RUN=1; shift ;;
        -h|--help)        usage ;;
        -*)               die "unknown option: $1" ;;
        *)                [[ -z "$TARGET" ]] || die "target 은 하나만 지정"; TARGET="$1"; shift ;;
    esac
done

command -v docker >/dev/null || die "docker 를 찾을 수 없습니다."
[[ -f "$CONF" ]] || die "targets.conf 없음: $CONF"

# ---------------------------------------------------------------------------
# targets.conf 로드  (bash 배열 사용 -> 반드시 bash 로 실행할 것)
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
source "$CONF"

if [[ "$DO_LIST" == "1" ]]; then
    echo "# targets in $CONF"
    compgen -v | sed -n 's/_seed_dir$//p' | sort
    exit 0
fi

[[ -n "$TARGET" ]] || die "target 미지정. '$0 --list' 로 목록 확인."

# 타겟명 -> conf 변수 prefix (하이픈은 bash 변수명에 못 쓰므로 '_' 로 변환)
#   gdk-pixbuf-pixdata  ->  gdk_pixbuf_pixdata
PREFIX="${TARGET//-/_}"

# ---------------------------------------------------------------------------
# conf 조회 (nameref 사용: 빈 배열 sqlite3_args=( ) 도 안전하게 처리)
# ---------------------------------------------------------------------------
[[ -v "${PREFIX}_args" || -n "$(declare -p "${PREFIX}_args" 2>/dev/null || true)" ]] \
    || die "'${PREFIX}_args' 없음 (target=$TARGET). --list 로 확인하세요."
declare -n _args_ref="${PREFIX}_args"

[[ -n "$(declare -p "${PREFIX}_seed_dir" 2>/dev/null || true)" ]] \
    || die "'${PREFIX}_seed_dir' 없음 (target=$TARGET)"
declare -n _seed_ref="${PREFIX}_seed_dir"

TARGET_ARGS=( ${_args_ref[@]+"${_args_ref[@]}"} )   # 빈 배열 안전
SEED_SUBDIR="$_seed_ref"

STDIN_FLAG=0
if [[ -n "$(declare -p "${PREFIX}_stdin_from_file" 2>/dev/null || true)" ]]; then
    declare -n _stdin_ref="${PREFIX}_stdin_from_file"
    [[ "$_stdin_ref" == "1" ]] && STDIN_FLAG=1
fi

# ---------------------------------------------------------------------------
# 임시 작업 디렉토리 (seed staging + inner script 용)
# ---------------------------------------------------------------------------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# seed 경로 결정
#   --seed  : 파일 또는 디렉토리 (매핑 무시)
#   -s      : 루트. 뒤에 conf 의 <seed_dir> 를 붙임
# ---------------------------------------------------------------------------
if [[ -n "$SEED_PATH" ]]; then
    RAW_SEED="$SEED_PATH"
else
    RAW_SEED="$SEEDS_ROOT/$SEED_SUBDIR"
    # 흔한 실수: -s 에 seed 파일/큐 디렉토리를 직접 넘긴 경우
    if [[ ! -d "$RAW_SEED" ]]; then
        if [[ -f "$SEEDS_ROOT" ]]; then
            die "-s 는 seed '루트'입니다 (뒤에 '$SEED_SUBDIR' 를 붙임).
    파일 하나를 쓰려면:  --seed $SEEDS_ROOT"
        elif [[ -d "$SEEDS_ROOT" ]]; then
            die "seed 디렉토리 없음: $RAW_SEED
    -s 는 seed 루트라서 '$SEED_SUBDIR' 를 붙입니다.
    이 디렉토리를 그대로 쓰려면:  --seed $SEEDS_ROOT"
        else
            die "seed 경로 없음: $RAW_SEED"
        fi
    fi
fi
[[ -e "$RAW_SEED" ]] || die "seed 경로 없음: $RAW_SEED"

# staging 이 필요한 경우:
#   (a) 단일 파일        -> 디렉토리로 감싸야 마운트/루프가 성립
#   (b) 경로에 ':' 포함  -> docker -v 가 콜론을 구분자로 파싱해 깨짐
#                           (예: Angora queue 의 id:001758)
SEED_STAGED=0
if [[ -f "$RAW_SEED" ]]; then
    SEED_STAGED=1
    HOST_SEEDS="$WORK/seed_stage"
    mkdir -p "$HOST_SEEDS"
    # 원본 파일명 그대로 복사 (콜론 포함 OK: 컨테이너 내부 루프는 문제없음)
    cp -- "$RAW_SEED" "$HOST_SEEDS/$(basename -- "$RAW_SEED")"
    log "single seed 모드 -> staging: $(basename -- "$RAW_SEED")"
elif [[ -d "$RAW_SEED" ]]; then
    HOST_SEEDS=$(cd "$RAW_SEED" && pwd)
    if [[ "$HOST_SEEDS" == *:* ]]; then
        SEED_STAGED=1
        SRC="$HOST_SEEDS"
        HOST_SEEDS="$WORK/seed_stage"
        mkdir -p "$HOST_SEEDS"
        find "$SRC" -maxdepth 1 -type f -exec cp -t "$HOST_SEEDS" -- {} +
        log "seed 경로에 ':' 포함 -> docker -v 파싱 회피 위해 staging"
    fi
else
    die "seed 가 파일도 디렉토리도 아님: $RAW_SEED"
fi

# staging 안 한 경우에만 절대경로 재확인
[[ "$SEED_STAGED" == "1" ]] || HOST_SEEDS=$(cd "$HOST_SEEDS" && pwd)

# 실제 처리할 파일이 있는지 확인
shopt -s nullglob
_cnt=0; for _f in "$HOST_SEEDS"/*; do [[ -f "$_f" ]] && _cnt=$((_cnt+1)); done
[[ "$_cnt" -gt 0 ]] || die "seed 파일이 없습니다: $RAW_SEED"

mkdir -p "$OUTDIR"
OUTDIR=$(cd "$OUTDIR" && pwd)
[[ "$OUTDIR" == *:* ]] && die "출력 경로에 ':' 가 있으면 docker -v 가 깨집니다: $OUTDIR"

log "target      : $TARGET"
log "args        : ${TARGET_ARGS[*]-<none>}$( [[ $STDIN_FLAG == 1 ]] && echo '   (stdin < seed)' )"
log "host seeds  : $RAW_SEED  ($_cnt file(s))"
log "host outdir : $OUTDIR"

# ---------------------------------------------------------------------------
# 컨테이너 내부에서 돌 스크립트 생성
#   인자: $1=target  $2=stdin_flag  $3..=target args ('@@' = seed placeholder)
# ---------------------------------------------------------------------------
INNER="$WORK/drcov_inner.sh"

cat > "$INNER" <<'INNER_EOF'
#!/usr/bin/env bash
set -uo pipefail

TARGET="$1"; shift
STDIN_FLAG="$1"; shift
ARG_TEMPLATE=( "$@" )

COV_DIR="${COV_DIR:-/d/p/cov}"
SEEDS_IN="${SEEDS_IN:-/mnt/seeds}"
OUT_IN="${OUT_IN:-/mnt/drcov_out}"
RUN_TIMEOUT="${RUN_TIMEOUT:-60}"

BINARY="$COV_DIR/$TARGET"
[[ -x "$BINARY" ]] || { echo "[!] 컨테이너 내 바이너리 없음: $BINARY" >&2; exit 1; }

# --- DynamoRIO 경로 탐색 (+ 미해제 tarball 자동 해제) ----------------------
DR_ROOT=$(ls -d "$COV_DIR"/DynamoRIO-Linux-*/ 2>/dev/null | head -n1 || true)
if [[ -z "$DR_ROOT" ]]; then
    TARBALL=$(ls "$COV_DIR"/DynamoRIO-Linux-*.tar.gz 2>/dev/null | head -n1 || true)
    if [[ -n "$TARBALL" ]]; then
        echo "[*] DynamoRIO 미해제 상태 -> 임시 해제: $TARBALL" >&2
        tar -xzf "$TARBALL" -C "$COV_DIR"/ 2>/dev/null \
            || { mkdir -p /tmp/dr && tar -xzf "$TARBALL" -C /tmp/dr; }
        DR_ROOT=$(ls -d "$COV_DIR"/DynamoRIO-Linux-*/ /tmp/dr/DynamoRIO-Linux-*/ 2>/dev/null | head -n1 || true)
    fi
fi
[[ -n "$DR_ROOT" ]] || { echo "[!] DynamoRIO 를 찾을 수 없습니다 ($COV_DIR/DynamoRIO-Linux-*/)" >&2; exit 1; }
DR_ROOT="${DR_ROOT%/}"

# --- bit 판별: ELF EI_CLASS (offset 4)  1=32bit, 2=64bit -------------------
# 'file' 패키지 유무에 의존하지 않도록 od 로 헤더를 직접 읽는다.
MAGIC=$(od -An -t x1 -N 4 "$BINARY" | tr -d ' \n')
[[ "$MAGIC" == "7f454c46" ]] || { echo "[!] ELF 파일이 아님: $BINARY" >&2; exit 1; }
EI_CLASS=$(od -An -t u1 -j 4 -N 1 "$BINARY" | tr -d ' \n')
case "$EI_CLASS" in
    2) BITS=64; DRRUN="$DR_ROOT/bin64/drrun" ;;
    1) BITS=32; DRRUN="$DR_ROOT/bin32/drrun" ;;
    *) echo "[!] EI_CLASS 판별 실패: $EI_CLASS" >&2; exit 1 ;;
esac
[[ -x "$DRRUN" ]] || { echo "[!] drrun 없음: $DRRUN (${BITS}bit 지원 빌드인지 확인)" >&2; exit 1; }

echo "[*] container: $TARGET  ${BITS}bit  drrun=$DRRUN"
mkdir -p "$OUT_IN"

ok=0; fail=0
shopt -s nullglob
for seed in "$SEEDS_IN"/*; do
    [[ -f "$seed" ]] || continue

    base=$(basename "$seed")
    seedname="${base%.*}"; [[ -n "$seedname" ]] || seedname="$base"
    seedname="${seedname//[^A-Za-z0-9._-]/_}"

    logdir=$(mktemp -d)
    rundir=$(mktemp -d)          # tiffsplit 등 cwd 산출물 격리
    errf=$(mktemp)               # drrun/target 출력 (실패 진단용)
    rc=0

    # '@@' -> seed 절대경로 치환
    args=()
    for tok in ${ARG_TEMPLATE[@]+"${ARG_TEMPLATE[@]}"}; do
        [[ "$tok" == "@@" ]] && tok="$seed"
        args+=( "$tok" )
    done

    if [[ "$STDIN_FLAG" == "1" ]]; then
        ( cd "$rundir" && timeout -k 5 "$RUN_TIMEOUT" \
            "$DRRUN" -t drcov -logdir "$logdir" -- \
            "$BINARY" ${args[@]+"${args[@]}"} < "$seed" ) >"$errf" 2>&1 || rc=$?
    else
        ( cd "$rundir" && timeout -k 5 "$RUN_TIMEOUT" \
            "$DRRUN" -t drcov -logdir "$logdir" -- \
            "$BINARY" ${args[@]+"${args[@]}"} ) >"$errf" 2>&1 || rc=$?
    fi

    # drcov 산출물: drcov.<app>.<pid>.NNNN.proc.log
    # NOTE: nullglob 이 켜져 있으므로 절대 `ls -t "$logdir"/drcov.*.log` 를 쓰면 안 된다.
    #       매치가 없으면 glob 이 사라져 `ls -t` 가 인자 없이 cwd 를 나열하고,
    #       그 결과 엉뚱한 디렉토리를 mv 하게 된다.
    produced=""
    logs=( "$logdir"/drcov.*.log )
    if (( ${#logs[@]} > 0 )); then
        # 자식 프로세스가 있으면 로그가 여러 개일 수 있다 -> 타겟 이름 매칭 우선, 없으면 최신
        for f in "${logs[@]}"; do
            [[ "$(basename "$f")" == drcov."$TARGET".* ]] && produced="$f" && break
        done
        if [[ -z "$produced" ]]; then
            for f in "${logs[@]}"; do
                [[ -z "$produced" || "$f" -nt "$produced" ]] && produced="$f"
            done
        fi
    fi

    if [[ -n "$produced" ]]; then
        mv -- "$produced" "$OUT_IN/${TARGET}_${seedname}.log"
        extra=""
        (( ${#logs[@]} > 1 )) && extra="  (drcov log ${#logs[@]}개 중 1개 선택)"
        echo "    [+] ${TARGET}_${seedname}.log (exit=$rc)$extra"
        ok=$((ok+1))
    else
        echo "    [-] FAIL: $base (exit=$rc) - drcov log 생성 안 됨" >&2
        if [[ -s "$errf" ]]; then
            echo "        ---- drrun/target 출력 (마지막 15줄) ----" >&2
            tail -n 15 "$errf" | sed 's/^/        /' >&2
            echo "        ----------------------------------------" >&2
        else
            echo "        (출력 없음)" >&2
        fi
        fail=$((fail+1))
    fi
    rm -rf "$logdir" "$rundir" "$errf"
done

# 하나도 성공 못했으면 원인 힌트 출력
if [[ "$ok" == "0" ]]; then
    echo "" >&2
    echo "[!] drcov log 를 하나도 만들지 못했습니다. 흔한 원인:" >&2
    echo "    1) 컨테이너에 SYS_PTRACE / seccomp 권한이 없음 (docker exec 모드에서 흔함)" >&2
    echo "       -> 컨테이너를 아래처럼 다시 띄우세요:" >&2
    echo "          docker run -d --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \\" >&2
    echo "                 -v /data2:/data2 <image> sleep infinity" >&2
    echo "    2) 타겟이 seed 를 거부하고 즉시 종료 (인자 매핑 확인)" >&2
    echo "    3) DynamoRIO 가 해당 바이너리를 attach 하지 못함" >&2
    echo "       -> 위 'drrun/target 출력' 을 확인하세요." >&2
fi

# bind-mount 로 호스트에 나가는 파일 소유권 보정 (root 로 생성되는 문제)
if [[ -n "${HOST_UID:-}" && -n "${HOST_GID:-}" && "$(id -u)" == "0" ]]; then
    chown -R "$HOST_UID:$HOST_GID" "$OUT_IN" 2>/dev/null || true
fi

echo "[*] done. ok=$ok fail=$fail"
[[ "$ok" -gt 0 ]] || exit 1
INNER_EOF
chmod +x "$INNER"

# ---------------------------------------------------------------------------
# 실행: docker run(기본) 또는 docker exec(-C)
# ---------------------------------------------------------------------------
# DynamoRIO 는 클라이언트 주입 위해 ptrace / 메모리 레이아웃 제어가 필요하다.
DOCKER_SEC=( --cap-add=SYS_PTRACE --security-opt seccomp=unconfined )

if [[ -n "$CONTAINER" ]]; then
    # ---------- exec 모드 ----------
    # 주의: docker exec 는 새 bind-mount 를 추가할 수 없다 -> docker cp 로 주고받는다.
    docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true \
        || die "실행 중인 컨테이너가 아님: $CONTAINER"

    # docker exec 는 실행 중 컨테이너의 보안 프로파일을 바꿀 수 없다.
    # DynamoRIO 는 클라이언트 주입에 ptrace/메모리 제어가 필요하므로 미리 점검한다.
    _caps=$(docker inspect -f '{{.HostConfig.CapAdd}} {{.HostConfig.Privileged}} {{.HostConfig.SecurityOpt}}' "$CONTAINER" 2>/dev/null || true)
    if [[ "$_caps" != *SYS_PTRACE* && "$_caps" != *true* && "$_caps" != *seccomp* ]]; then
        log "WARNING: '$CONTAINER' 에 SYS_PTRACE / seccomp=unconfined 설정이 안 보입니다."
        log "         DynamoRIO 주입이 실패할 수 있습니다. 실패하면 컨테이너를 이렇게 다시 띄우세요:"
        log "           docker run -d --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \\"
        log "                  -v /data2:/data2 <image> sleep infinity"
    fi

    TMP_IN="/tmp/drcov_$$"
    log "mode: docker exec ($CONTAINER)  [seeds 는 docker cp 로 복사]"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "docker exec $CONTAINER mkdir -p $TMP_IN/seeds $TMP_IN/out"
        echo "docker cp $HOST_SEEDS/. $CONTAINER:$TMP_IN/seeds"
        echo "docker cp $INNER $CONTAINER:$TMP_IN/run.sh"
        echo "docker exec -e SEEDS_IN=$TMP_IN/seeds -e OUT_IN=$TMP_IN/out $CONTAINER bash $TMP_IN/run.sh $TARGET $STDIN_FLAG ${TARGET_ARGS[*]-}"
        echo "docker cp $CONTAINER:$TMP_IN/out/. $OUTDIR"
        exit 0
    fi

    docker exec "$CONTAINER" mkdir -p "$TMP_IN/seeds" "$TMP_IN/out"
    docker cp "$HOST_SEEDS/." "$CONTAINER:$TMP_IN/seeds"
    docker cp "$INNER" "$CONTAINER:$TMP_IN/run.sh"

    set +e
    docker exec \
        -e SEEDS_IN="$TMP_IN/seeds" \
        -e OUT_IN="$TMP_IN/out" \
        -e RUN_TIMEOUT="$RUN_TIMEOUT" \
        -e COV_DIR="$COV_DIR" \
        "$CONTAINER" bash "$TMP_IN/run.sh" "$TARGET" "$STDIN_FLAG" ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}
    RC=$?
    set -e

    docker cp "$CONTAINER:$TMP_IN/out/." "$OUTDIR" 2>/dev/null || true
    docker exec "$CONTAINER" rm -rf "$TMP_IN" 2>/dev/null || true
    log "logs -> $OUTDIR"
    exit "$RC"
else
    # ---------- run 모드 (권장) ----------
    log "mode: docker run ($IMAGE)"
    DOCKER_CMD=( docker run --rm
        "${DOCKER_SEC[@]}"
        -v "$HOST_SEEDS:/mnt/seeds:ro"
        -v "$OUTDIR:/mnt/drcov_out"
        -v "$INNER:/mnt/run.sh:ro"
        -e SEEDS_IN=/mnt/seeds
        -e OUT_IN=/mnt/drcov_out
        -e RUN_TIMEOUT="$RUN_TIMEOUT"
        -e COV_DIR="$COV_DIR"
        -e HOST_UID="$(id -u)"
        -e HOST_GID="$(id -g)"
        "$IMAGE"
        bash /mnt/run.sh "$TARGET" "$STDIN_FLAG" ${TARGET_ARGS[@]+"${TARGET_ARGS[@]}"}
    )
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '%q ' "${DOCKER_CMD[@]}"; echo
        exit 0
    fi
    "${DOCKER_CMD[@]}"
    log "logs -> $OUTDIR"
fi