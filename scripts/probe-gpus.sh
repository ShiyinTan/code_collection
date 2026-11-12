#!/usr/bin/env bash
# probe-gpus.sh — List gpu01..gpu30 hosts that have GPUs.
#
# Run on a lab host that can SSH to the GPUs (peter or a gpuNN box):
#   ./scripts/probe-gpus.sh
#
# SSH to each host (user: $USER or lidy). If nvidia-smi reports ≥1 GPU,
# write the hostname. Skip unreachable hosts or hosts with no GPU.
#
# Outputs (under the repo, not $PWD):
#   results/available-hosts.txt  — hostnames only, one per line
#   results/gpu-status.txt       — included / skipped reasons
#
# Optional: -u USER, --hosts 01,05,10-12, -o OUT, --status STATUS
# SSH for the probe disables known_hosts checks (lab keys change often).

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
OUT="${OUT:-results/available-hosts.txt}"
STATUS_OUT="${STATUS_OUT:-results/gpu-status.txt}"
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
    --status) STATUS_OUT=$2; shift 2 ;;
    -p|--parallel) PARALLEL=$2; shift 2 ;;
    --hosts) HOST_SPEC=$2; shift 2 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage 2
      ;;
  esac
done

OUT=$(repo_path "$OUT")
STATUS_OUT=$(repo_path "$STATUS_OUT")

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

# Count GPUs; always exit 0 so a busy/empty query cannot fail SSH.
REMOTE_CMD=$(cat <<'EOS'
set +e
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo 'COUNT|0|no_nvidia_smi'
  exit 0
fi
n=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | grep -c . || true)
echo "COUNT|${n}|ok"
exit 0
EOS
)

# Lab LAN: host keys often rotate / DNS+IP collide in known_hosts.
# accept-new is NOT enough for *changed* keys (BatchMode then fails rc=255).
# For this probe only, ignore known_hosts so we still connect non-interactively.
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
  echo "# include host if nvidia-smi reports ≥1 GPU (busy or free)"
  echo
} >"$STATUS_OUT"

listed=0
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
  count_line=$(grep '^COUNT|' "$raw" | head -1 || true)
  if [[ -z $count_line ]]; then
    echo "${host}: SKIP no COUNT line from remote" >>"$STATUS_OUT"
    echo "${host}: bad remote output" >&2
    continue
  fi

  IFS='|' read -r _ count meta <<<"$count_line"
  count=${count:-0}
  meta=${meta:-}

  if [[ $meta == no_nvidia_smi ]]; then
    echo "${host}: SKIP no nvidia-smi" >>"$STATUS_OUT"
    echo "${host}: no nvidia-smi" >&2
    continue
  fi

  if ! [[ $count =~ ^[0-9]+$ ]] || ((count < 1)); then
    echo "${host}: SKIP no GPU (count=${count})" >>"$STATUS_OUT"
    echo "${host}: no GPU" >&2
    continue
  fi

  printf '%s\n' "$host" >>"$OUT"
  listed=$((listed + 1))
  echo "${host}: OK gpus=${count}" >>"$STATUS_OUT"
done

{
  echo
  echo "# summary: reachable ${reachable}/${#HOSTS[@]}, unreachable ${unreachable}, hosts with GPU ${listed}"
} >>"$STATUS_OUT"

echo "Reachable: ${reachable}/${#HOSTS[@]}; unreachable: ${unreachable}; hosts with GPU: ${listed}" >&2
echo "Wrote: ${OUT}" >&2
echo "Wrote: ${STATUS_OUT}" >&2
