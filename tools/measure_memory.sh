#!/bin/bash

##
# Usage:
#   ./measure_memory.sh <container_name_or_id>
#   ./measure_memory.sh               # 실행 중인 angora 컨테이너 자동 탐지
##

# ── 컨테이너 결정 ──────────────────────────────────────────────
if [ -n "$1" ]; then
    CID="$1"
else
    CID=$(docker ps --format '{{.Names}}' | grep angora | head -1)
    if [ -z "$CID" ]; then
        echo "Error: 실행 중인 angora 컨테이너를 찾을 수 없습니다."
        echo "Usage: $0 <container_name_or_id>"
        exit 1
    fi
    echo "[자동 탐지] 컨테이너: $CID"
fi

if ! docker inspect "$CID" &>/dev/null; then
    echo "Error: 컨테이너 '$CID' 를 찾을 수 없습니다."
    exit 1
fi

# ── 기본 정보 수집 ─────────────────────────────────────────────
HOST_PID=$(docker inspect "$CID" --format '{{.State.Pid}}')
if [ -z "$HOST_PID" ] || [ "$HOST_PID" -eq 0 ]; then
    echo "Error: 컨테이너가 실행 중이 아닙니다."
    exit 1
fi

CGROUP_REL=$(cat /proc/$HOST_PID/cgroup | grep -oP '(?<=0::).*')
CGROUP_ROOT="/sys/fs/cgroup${CGROUP_REL}"

SEP="─────────────────────────────────────────────"

# 컨테이너 내 모든 자손 PID를 재귀적으로 수집
get_descendants() {
    local pid=$1
    echo $pid
    for child in $(pgrep -P $pid 2>/dev/null); do
        get_descendants $child
    done
}

# ── 출력 ───────────────────────────────────────────────────────
echo ""
echo "====== Memory Report: $CID ======"
echo "Host init PID : $HOST_PID"
echo "cgroup path   : $CGROUP_ROOT"
echo ""

# 1. cgroup 총합
echo "[ 1 ] cgroup 전체 메모리 (가장 정확한 총합)"
echo "$SEP"
total=$(cat ${CGROUP_ROOT}/memory.current 2>/dev/null)
if [ -n "$total" ]; then
    printf "  Total : %d bytes = %.2f MB\n" $total $(awk "BEGIN{printf \"%.2f\", $total/1048576}")
else
    echo "  cgroup memory.current 파일을 읽을 수 없습니다."
fi
echo ""

# 2. memory.stat 세부 분류
echo "[ 2 ] 항목별 분류 (memory.stat)"
echo "$SEP"
if [ -f "${CGROUP_ROOT}/memory.stat" ]; then
    grep -E "^(anon|file|shmem|kernel|kernel_stack|pagetables|file_mapped) " \
        ${CGROUP_ROOT}/memory.stat | \
        awk '{printf "  %-15s %10.2f MB\n", $1, $2/1048576}'
else
    echo "  memory.stat 파일을 읽을 수 없습니다."
fi
echo ""

# 3. SHM 세그먼트 (IPC 네임스페이스가 컨테이너 내부라 docker exec 필요)
echo "[ 3 ] SHM 세그먼트 (컨테이너 IPC 네임스페이스)"
echo "$SEP"
docker exec "$CID" ipcs -m 2>/dev/null | awk '
/^--/ || /^key/ || NF==0 { next }
{
    mb = $5/1048576
    printf "  shmid %-4s  %10.2f MB  nattch=%-2s  %s\n", $2, mb, $6, $7
    sum += $5
}
END { printf "  %s\n  SHM 합계 : %.2f MB\n", "─────────────────────────────────────", sum/1048576 }
'
echo ""

# 4. 컨테이너 내 프로세스별 RSS (호스트 /proc 직접 읽기)
echo "[ 4 ] 프로세스별 RSS (호스트 /proc 기준)"
echo "$SEP"
printf "  %-8s %-30s %10s\n" "PID" "COMMAND" "RSS"
printf "  %-8s %-30s %10s\n" "───────" "──────────────────────────────" "──────────"

total_rss=0
for pid in $(get_descendants $HOST_PID | sort -u); do
    [ -f /proc/$pid/status ] || continue
    comm=$(cat /proc/$pid/comm 2>/dev/null | cut -c1-29)
    rss=$(grep VmRSS /proc/$pid/status 2>/dev/null | awk '{print $2}')
    [ -z "$rss" ] && continue
    printf "  %-8s %-30s %7.2f MB\n" $pid "$comm" $(awk "BEGIN{printf \"%.2f\", $rss/1024}")
    total_rss=$((total_rss + rss))
done

printf "  %-8s %-30s %10s\n" "───────" "──────────────────────────────" "──────────"
printf "  %-38s %7.2f MB\n" "RSS 합계 (SHM 중복 포함)" $(awk "BEGIN{printf \"%.2f\", $total_rss/1024}")
echo ""

# 5. docker stats 요약
echo "[ 5 ] docker stats 요약"
echo "$SEP"
docker stats --no-stream --format \
    "  MEM Usage : {{.MemUsage}}\n  MEM %     : {{.MemPerc}}\n  CPU %     : {{.CPUPerc}}" \
    "$CID"
echo ""
