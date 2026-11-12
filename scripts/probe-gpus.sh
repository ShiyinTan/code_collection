#!/usr/bin/env bash
# probe-gpus.sh — From peter, find free GPUs on gpu01..gpu30.
#
# Run ON peter (already on the lab network):
#   ./scripts/probe-gpus.sh
#
# SSHs directly to each gpuNN (same user; default: $USER or lidy), runs
# nvidia-smi, and writes free GPUs to:
#   results/available-gpus.txt
#
# Optional:
#   ./scripts/probe-gpus.sh -u lidy
#   ./scripts/probe-gpus.sh --hosts 01,05,10-12
#   OUT=results/available-gpus.txt ./scripts/probe-gpus.sh
#
# Needs bash, ssh keys/agent (BatchMode), remote nvidia-smi.

set -euo pipefail

REMOTE_USER="${REMOTE_USER:-${USER:-lidy}}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
PARALLEL="${PARALLEL:-8}"
OUT="${OUT:-results/available-gpus.txt}"
HOST_SPEC=""

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

parse_host_spec() {
  local spec=$1 part start end i h
  IFS=',' read -ra parts <<< "$spec"
  for part in "${parts[@]}"; do
    part=$(trim "$part")
    if [[ $part =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start=$((10#${BASH_REMATCH[1]}))
      end=$((10#${BASH_REMATCH[2]}))
      for ((i = start; i <= end; i++)); do
        printf -v h '%02d' "$i"
        echo "gpu${h}"
      done
    elif [[ $part =~ ^gpu([0-9]+)$ ]]; then
      printf -v h '%02d' "$((10#${BASH_REMATCH[1]}))"
      echo "gpu${h}"
    elif [[ $part =~ ^([0-9]+)$ ]]; then
      printf -v h '%02d' "$((10#${BASH_REMATCH[1]}))"
      echo "gpu${h}"
    else
      echo "error: bad host token: $part" >&2
      exit 2
    fi
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    -u|--user) REMOTE_USER=$2; shift 2 ;;
    -t|--timeout) CONNECT_TIMEOUT=$2; shift 2 ;;
    -o|--out) OUT=$2; shift 2 ;;
    -p|--parallel) PARALLEL=$2; shift 2 ;;
    --hosts) HOST_SPEC=$2; shift 2 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage 2
      ;;
  esac
done

HOSTS=()
if [[ -n $HOST_SPEC ]]; then
  mapfile -t HOSTS < <(parse_host_spec "$HOST_SPEC")
else
  for i in $(seq -w 1 30); do
    HOSTS+=("gpu${i}")
  done
fi

mkdir -p "$(dirname "$OUT")"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/probe-gpus.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# On the GPU box: print "INDEX|NAME" for free GPUs (0% util, <50 MiB used).
REMOTE_CMD=$(cat <<'EOS'
if ! command -v nvidia-smi >/dev/null 2>&1; then
  exit 0
fi
nvidia-smi --query-gpu=index,name,memory.used,utilization.gpu --format=csv,noheader,nounits 2>/dev/null \
  | while IFS=',' read -r idx name mem util; do
      idx=$(echo "$idx" | tr -d ' ')
      name=$(echo "$name" | sed 's/^ *//;s/ *$//')
      mem=$(echo "$mem" | tr -d ' ')
      util=$(echo "$util" | tr -d ' ')
      [[ $mem == \[N/A\] ]] && mem=0
      [[ $util == \[N/A\] ]] && util=0
      if [[ $util =~ ^[0-9]+$ && $mem =~ ^[0-9]+$ ]] && ((util == 0 && mem < 50)); then
        printf '%s|%s\n' "$idx" "$name"
      fi
    done
EOS
)

probe_one() {
  local host=$1
  if ssh \
    -o BatchMode=yes \
    -o ConnectTimeout="$CONNECT_TIMEOUT" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectionAttempts=1 \
    "${REMOTE_USER}@${host}" \
    "$REMOTE_CMD" >"${TMP}/${host}.out" 2>"${TMP}/${host}.err"
  then
    echo ok >"${TMP}/${host}.status"
  else
    echo fail >"${TMP}/${host}.status"
  fi
}

echo "Probing ${#HOSTS[@]} hosts as ${REMOTE_USER}@gpuNN (timeout=${CONNECT_TIMEOUT}s)"

running=0
for host in "${HOSTS[@]}"; do
  probe_one "$host" &
  running=$((running + 1))
  if ((running >= PARALLEL)); then
    wait -n 2>/dev/null || true
    running=$(jobs -pr | wc -l | tr -d ' ')
  fi
done
wait

{
  echo "# available GPUs — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# format: host  gpu_index  name"
  echo "# ssh user: ${REMOTE_USER}"
  echo
} >"$OUT"

available=0
reachable=0
for host in "${HOSTS[@]}"; do
  status=$(cat "${TMP}/${host}.status" 2>/dev/null || echo fail)
  [[ $status == ok ]] || continue
  reachable=$((reachable + 1))
  while IFS='|' read -r idx name || [[ -n ${idx:-} ]]; do
    [[ -z ${idx:-} ]] && continue
    printf '%s\t%s\t%s\n' "$host" "$idx" "$name" >>"$OUT"
    available=$((available + 1))
  done <"${TMP}/${host}.out"
done

echo "Reachable: ${reachable}/${#HOSTS[@]}; free GPUs: ${available}"
echo "Wrote: ${OUT}"
