#!/usr/bin/env bash
# find-free-gpus.sh — On hosts from available-hosts.txt, list free GPU indices.
#
# Run on a lab host that can SSH to the GPUs (peter or a gpuNN box), after probe:
#   ./scripts/probe-gpus.sh
#   ./scripts/find-free-gpus.sh
#
# Reads hostnames from results/available-hosts.txt (one per line; # comments OK).
# Free GPU = no nvidia compute process on that device (residual memory/util alone
# does not mark a GPU busy).
#
# Output line format (results/free-gpus.txt + stdout):
#   host:index  name  free_mib/total_mib MiB
# e.g. gpu03:0  NVIDIA GeForce RTX 3090  24200/24564 MiB
#
# Optional: -u USER, -i HOSTS_FILE, -o OUT
# SSH options match probe-gpus.sh (BatchMode; ignore known_hosts for lab keys).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# Resolve relative paths against the repo root so aliases work from any cwd.
repo_path() {
  local p=$1
  if [[ $p = /* ]]; then
    printf '%s' "$p"
  else
    printf '%s' "${REPO_ROOT}/${p}"
  fi
}

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

# True if s looks like a usable nvidia UUID (non-empty, not [N/A]).
valid_uuid() {
  local s=$1
  [[ -n $s && $s != \[N/A\] && $s != N/A ]]
}

na_num() {
  # Normalize nvidia [N/A] / blank to 0 for arithmetic.
  local s
  s=$(trim "${1:-0}")
  if [[ -z $s || $s == \[N/A\] || $s == N/A ]]; then
    echo 0
  else
    echo "$s"
  fi
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

HOSTS_FILE=$(repo_path "$HOSTS_FILE")
OUT=$(repo_path "$OUT")

if [[ ! -f $HOSTS_FILE ]]; then
  echo "error: host list not found: ${HOSTS_FILE}" >&2
  echo "Run ./scripts/probe-gpus.sh (or gpu-probe) first on this host (or any lab host with SSH to the GPUs), then retry." >&2
  exit 1
fi

HOSTS=()
while IFS= read -r line || [[ -n ${line:-} ]]; do
  line=$(trim "$line")
  [[ -z $line || $line == \#* ]] && continue
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

# name last so commas in the name (rare) do not break fixed fields.
# Always exit 0 after query so SSH does not look like failure.
REMOTE_CMD=$(cat <<'EOS'
set +e
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo 'META|no_nvidia_smi'
  exit 0
fi
echo 'META|ok'
echo '---GPUS---'
nvidia-smi --query-gpu=index,uuid,memory.used,memory.total,name \
  --format=csv,noheader,nounits 2>/dev/null
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
  echo "# format: host:index  name  free_mib/total_mib MiB"
  echo "# free = no nvidia compute process on that GPU"
  echo "# hosts file: ${HOSTS_FILE}"
  echo "# ssh user: ${REMOTE_USER}"
  echo
} >"$OUT"

free_total=0
hosts_with_free=0
unreachable=0
reachable=0

record_free() {
  local host=$1 idx=$2 name=$3 mem_used=$4 mem_total=$5
  local free_mib line
  mem_used=$(na_num "$mem_used")
  mem_total=$(na_num "$mem_total")
  free_mib=$((mem_total - mem_used))
  if ((free_mib < 0)); then free_mib=0; fi
  [[ -n $name ]] || name='(unknown)'
  line=$(printf '%s:%s  %s  %s/%s MiB' "$host" "$idx" "$name" "$free_mib" "$mem_total")
  printf '%s\n' "$line" >>"$OUT"
  free_lines+=("$line")
  free_total=$((free_total + 1))
}

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

  # Never index associative arrays with an empty key (bash: "bad array subscript").
  declare -A busy_uuid=()
  while IFS= read -r line || [[ -n ${line:-} ]]; do
    line=$(trim "$line")
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == gpu_uuid* || $line == \[N/A\]* ]] && continue
    IFS=',' read -r guuid pid _rest <<<"$line"
    guuid=$(trim "${guuid:-}")
    pid=$(trim "${pid:-}")
    valid_uuid "$guuid" || continue
    [[ -n $pid && $pid != \[N/A\] && $pid != N/A ]] || continue
    busy_uuid[$guuid]=1
  done <<<"$procs_block"

  free_lines=()
  while IFS= read -r line || [[ -n ${line:-} ]]; do
    line=$(trim "$line")
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == index* ]] && continue
    # index, uuid, mem.used, mem.total, name...
    IFS=',' read -r idx uuid mem_used mem_total name_rest <<<"$line"
    idx=$(trim "${idx:-}")
    uuid=$(trim "${uuid:-}")
    mem_used=$(trim "${mem_used:-}")
    mem_total=$(trim "${mem_total:-}")
    name=$(trim "${name_rest:-}")
    [[ -n $idx && $idx != \[N/A\] ]] || continue

    is_free=0
    if ! valid_uuid "$uuid"; then
      if ((${#busy_uuid[@]} == 0)); then
        is_free=1
      fi
    elif [[ -z ${busy_uuid[$uuid]+x} ]]; then
      is_free=1
    fi

    if ((is_free)); then
      record_free "$host" "$idx" "$name" "$mem_used" "$mem_total"
    fi
  done <<<"$gpus_block"

  if ((${#free_lines[@]} > 0)); then
    hosts_with_free=$((hosts_with_free + 1))
    echo "${host}:"
    for fl in "${free_lines[@]}"; do
      echo "  ${fl}"
    done
  else
    echo "${host}: no free GPU"
  fi

  unset busy_uuid free_lines
done

echo
echo "Summary: reachable ${reachable}/${#HOSTS[@]}, unreachable ${unreachable}, free GPUs ${free_total} on ${hosts_with_free} host(s)"
echo "Wrote: ${OUT}"
