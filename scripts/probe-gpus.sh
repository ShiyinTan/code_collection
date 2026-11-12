#!/usr/bin/env bash
# probe-gpus.sh — From peter, list GPU hosts that have at least one free GPU.
#
# Run ON peter:
#   ./scripts/probe-gpus.sh
#
# SSH to gpu01..gpu30 (user: $USER or lidy). A GPU is free when it has no
# compute processes. If a host has ≥1 free GPU, its hostname is listed.
#
# Outputs:
#   results/available-hosts.txt  — hostnames only, one per line (e.g. gpu03)
#   results/gpu-status.txt       — why each host was included or skipped
#
# Optional: -u USER, --hosts 01,05,10-12, -o OUT, --status STATUS

set -euo pipefail

REMOTE_USER="${REMOTE_USER:-${USER:-lidy}}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-8}"
PARALLEL="${PARALLEL:-8}"
OUT="${OUT:-results/available-hosts.txt}"
STATUS_OUT="${STATUS_OUT:-results/gpu-status.txt}"
HOST_SPEC=""

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
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
    --status) STATUS_OUT=$2; shift 2 ;;
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

mkdir -p "$(dirname "$OUT")" "$(dirname "$STATUS_OUT")"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/probe-gpus.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Always exit 0 after querying so a busy last-GPU / read-EOF cannot make SSH
# look like failure (that bug previously dropped most free hosts).
REMOTE_CMD=$(cat <<'EOS'
set +e
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo 'META|no_nvidia_smi'
  exit 0
fi
echo 'META|ok'
echo '---GPUS---'
nvidia-smi --query-gpu=index,uuid,name,memory.used,memory.total,utilization.gpu \
  --format=csv,noheader,nounits 2>/dev/null
echo '---PROCS---'
nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory \
  --format=csv,noheader,nounits 2>/dev/null
exit 0
EOS
)

probe_one() {
  local host=$1
  local rc=0
  set +e
  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout="$CONNECT_TIMEOUT" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectionAttempts=1 \
    "${REMOTE_USER}@${host}" \
    "$REMOTE_CMD" >"${TMP}/${host}.out" 2>"${TMP}/${host}.err"
  rc=$?
  set -e
  echo "$rc" >"${TMP}/${host}.rc"
}

echo "Probing ${#HOSTS[@]} hosts as ${REMOTE_USER}@gpuNN (timeout=${CONNECT_TIMEOUT}s)" >&2

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

stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

: >"$OUT"

{
  echo "# GPU probe status — ${stamp}"
  echo "# ssh user: ${REMOTE_USER}"
  echo "# include host in available-hosts.txt if ≥1 GPU has no compute process"
  echo
} >"$STATUS_OUT"

available_hosts=0
reachable=0
unreachable=0

for host in "${HOSTS[@]}"; do
  rc=$(cat "${TMP}/${host}.rc" 2>/dev/null || echo 255)
  raw=${TMP}/${host}.out
  err=${TMP}/${host}.err

  if [[ $rc != 0 ]]; then
    unreachable=$((unreachable + 1))
    err_snip=$(tr '\n' ' ' <"$err" 2>/dev/null | head -c 160 || true)
    echo "${host}: SKIP unreachable (ssh rc=${rc}) ${err_snip}" >>"$STATUS_OUT"
    echo "${host}: unreachable" >&2
    continue
  fi

  reachable=$((reachable + 1))
  meta=$(sed -n 's/^META|//p' "$raw" | head -1)
  if [[ $meta == no_nvidia_smi ]]; then
    echo "${host}: SKIP no nvidia-smi" >>"$STATUS_OUT"
    echo "${host}: no nvidia-smi" >&2
    continue
  fi

  gpus_block=$(awk '/^---GPUS---$/{f=1;next}/^---PROCS---$/{f=0}f' "$raw")
  procs_block=$(awk '/^---PROCS---$/{f=1;next}f' "$raw")

  declare -A busy_uuid=()
  declare -A busy_detail=()
  while IFS= read -r line || [[ -n ${line:-} ]]; do
    [[ -z ${line// } ]] && continue
    IFS=',' read -r guuid pid pname used_mem <<<"$line"
    guuid=$(trim "$guuid")
    pid=$(trim "$pid")
    pname=$(trim "$pname")
    used_mem=$(trim "$used_mem")
    [[ -z $guuid || $guuid == \[N/A\] ]] && continue
    [[ -z $pid || $pid == \[N/A\] ]] && continue
    busy_uuid[$guuid]=1
    detail="pid=${pid} ${pname}"
    if [[ -n $used_mem && $used_mem != \[N/A\] ]]; then
      detail+=" (${used_mem} MiB)"
    fi
    if [[ -n ${busy_detail[$guuid]:-} ]]; then
      busy_detail[$guuid]="${busy_detail[$guuid]}; ${detail}"
    else
      busy_detail[$guuid]=$detail
    fi
  done <<<"$procs_block"

  free_idxs=()
  busy_idxs=()
  total=0

  while IFS= read -r line || [[ -n ${line:-} ]]; do
    [[ -z ${line// } ]] && continue
    IFS=',' read -r idx uuid name mem_used mem_total util <<<"$line"
    idx=$(trim "$idx")
    uuid=$(trim "$uuid")
    name=$(trim "$name")
    [[ -z $idx ]] && continue
    total=$((total + 1))
    if [[ -n ${busy_uuid[$uuid]:-} ]]; then
      busy_idxs+=("${idx}(${name}: ${busy_detail[$uuid]})")
    else
      free_idxs+=("$idx")
    fi
  done <<<"$gpus_block"

  if ((total == 0)); then
    echo "${host}: SKIP no GPUs reported" >>"$STATUS_OUT"
    echo "${host}: no GPUs reported" >&2
  elif ((${#free_idxs[@]} > 0)); then
    printf '%s\n' "$host" >>"$OUT"
    available_hosts=$((available_hosts + 1))
    echo "${host}: AVAILABLE free_gpus=${#free_idxs[@]}/${total} indexes=$(IFS=,; echo "${free_idxs[*]}")" >>"$STATUS_OUT"
  else
    echo "${host}: SKIP no free GPU (all ${total} busy)" >>"$STATUS_OUT"
    for b in "${busy_idxs[@]}"; do
      echo "  busy gpu${b}" >>"$STATUS_OUT"
    done
    echo "${host}: no free GPU" >&2
  fi

  unset busy_uuid busy_detail
done

{
  echo
  echo "# summary: reachable ${reachable}/${#HOSTS[@]}, unreachable ${unreachable}, hosts with free GPU ${available_hosts}"
} >>"$STATUS_OUT"

echo "Reachable: ${reachable}/${#HOSTS[@]}; unreachable: ${unreachable}; hosts with ≥1 free GPU: ${available_hosts}" >&2
echo "Wrote: ${OUT}" >&2
echo "Wrote: ${STATUS_OUT}" >&2
