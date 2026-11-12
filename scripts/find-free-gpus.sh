#!/usr/bin/env bash
# find-free-gpus.sh — On hosts from available-hosts.txt, list free GPU indices.
#
# Run ON peter, after probe-gpus.sh:
#   ./scripts/probe-gpus.sh
#   ./scripts/find-free-gpus.sh
#
# Reads hostnames from results/available-hosts.txt (one per line; # comments OK).
# Free GPU = no nvidia compute process on that device (residual memory/util alone
# does not mark a GPU busy). Format: host:index (e.g. gpu03:0).
#
# Outputs:
#   results/free-gpus.txt
# Also prints a short summary to stdout. Unreachable hosts are noted and skipped.
#
# Optional: -u USER, -i HOSTS_FILE, -o OUT
# SSH options match probe-gpus.sh (BatchMode; ignore known_hosts for lab keys).

set -euo pipefail

REMOTE_USER="${REMOTE_USER:-${USER:-lidy}}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-8}"
PARALLEL="${PARALLEL:-8}"
HOSTS_FILE="${HOSTS_FILE:-results/available-hosts.txt}"
OUT="${OUT:-results/free-gpus.txt}"

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    -u|--user) REMOTE_USER=$2; shift 2 ;;
    -t|--timeout) CONNECT_TIMEOUT=$2; shift 2 ;;
    -i|--hosts-file) HOSTS_FILE=$2; shift 2 ;;
    -o|--out) OUT=$2; shift 2 ;;
    -p|--parallel) PARALLEL=$2; shift 2 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage 2
      ;;
  esac
done

if [[ ! -f $HOSTS_FILE ]]; then
  echo "error: host list not found: ${HOSTS_FILE}" >&2
  echo "Run ./scripts/probe-gpus.sh first (on peter), then retry." >&2
  exit 1
fi

HOSTS=()
while IFS= read -r line || [[ -n ${line:-} ]]; do
  line=$(trim "$line")
  [[ -z $line || $line == \#* ]] && continue
  # allow "gpu03" or stray "gpu03:0" → take hostname before ':'
  host=${line%%:*}
  host=$(trim "$host")
  [[ -n $host ]] && HOSTS+=("$host")
done <"$HOSTS_FILE"

if ((${#HOSTS[@]} == 0)); then
  echo "error: no hosts in ${HOSTS_FILE}" >&2
  echo "Run ./scripts/probe-gpus.sh first, or check the file." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/find-free-gpus.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Dump GPU index/uuid/name + compute apps. Always exit 0 after query.
REMOTE_CMD=$(cat <<'EOS'
set +e
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo 'META|no_nvidia_smi'
  exit 0
fi
echo 'META|ok'
echo '---GPUS---'
nvidia-smi --query-gpu=index,uuid,name --format=csv,noheader,nounits 2>/dev/null
echo '---PROCS---'
nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory \
  --format=csv,noheader,nounits 2>/dev/null
exit 0
EOS
)

SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout="$CONNECT_TIMEOUT"
  -o ConnectionAttempts=1
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o GlobalKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

probe_one() {
  local host=$1
  local rc=0
  set +e
  ssh "${SSH_OPTS[@]}" \
    "${REMOTE_USER}@${host}" \
    "$REMOTE_CMD" >"${TMP}/${host}.out" 2>"${TMP}/${host}.err"
  rc=$?
  set -e
  echo "$rc" >"${TMP}/${host}.rc"
}

echo "Checking free GPUs on ${#HOSTS[@]} host(s) as ${REMOTE_USER} (from ${HOSTS_FILE})"

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
{
  echo "# free GPUs — ${stamp}"
  echo "# format: host:index"
  echo "# free = no nvidia compute process on that GPU"
  echo "# hosts file: ${HOSTS_FILE}"
  echo "# ssh user: ${REMOTE_USER}"
  echo
} >"$OUT"

free_total=0
hosts_with_free=0
unreachable=0
reachable=0

for host in "${HOSTS[@]}"; do
  rc=$(cat "${TMP}/${host}.rc" 2>/dev/null || echo 255)
  raw=${TMP}/${host}.out
  err=${TMP}/${host}.err

  if [[ $rc != 0 ]]; then
    unreachable=$((unreachable + 1))
    err_snip=$(tr '\n' ' ' <"$err" 2>/dev/null | head -c 120 || true)
    echo "skip ${host}: unreachable (ssh rc=${rc}) ${err_snip}"
    continue
  fi

  reachable=$((reachable + 1))
  meta=$(sed -n 's/^META|//p' "$raw" | head -1)
  if [[ $meta == no_nvidia_smi ]]; then
    echo "skip ${host}: no nvidia-smi"
    continue
  fi

  gpus_block=$(awk '/^---GPUS---$/{f=1;next}/^---PROCS---$/{f=0}f' "$raw")
  procs_block=$(awk '/^---PROCS---$/{f=1;next}f' "$raw")

  declare -A busy_uuid=()
  while IFS= read -r line || [[ -n ${line:-} ]]; do
    [[ -z ${line// } ]] && continue
    IFS=',' read -r guuid pid _rest <<<"$line"
    guuid=$(trim "$guuid")
    pid=$(trim "$pid")
    [[ -z $guuid || $guuid == \[N/A\] ]] && continue
    [[ -z $pid || $pid == \[N/A\] ]] && continue
    busy_uuid[$guuid]=1
  done <<<"$procs_block"

  free_idxs=()
  while IFS= read -r line || [[ -n ${line:-} ]]; do
    [[ -z ${line// } ]] && continue
    IFS=',' read -r idx uuid name <<<"$line"
    idx=$(trim "$idx")
    uuid=$(trim "$uuid")
    [[ -z $idx ]] && continue
    if [[ -z ${busy_uuid[$uuid]:-} ]]; then
      free_idxs+=("$idx")
      printf '%s:%s\n' "$host" "$idx" >>"$OUT"
      free_total=$((free_total + 1))
    fi
  done <<<"$gpus_block"

  if ((${#free_idxs[@]} > 0)); then
    hosts_with_free=$((hosts_with_free + 1))
    echo "${host}: free $(IFS=,; echo "${free_idxs[*]}")"
  else
    echo "${host}: no free GPU"
  fi

  unset busy_uuid
done

echo
echo "Summary: reachable ${reachable}/${#HOSTS[@]}, unreachable ${unreachable}, free GPUs ${free_total} on ${hosts_with_free} host(s)"
echo "Wrote: ${OUT}"
