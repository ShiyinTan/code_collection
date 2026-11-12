#!/usr/bin/env bash
# probe-gpus.sh — Probe gpu01..gpu30 for GPU occupancy via SSH jump host.
#
# Usage:
#   ./scripts/probe-gpus.sh
#   ./scripts/probe-gpus.sh --hosts 01,05,10-12
#   JUMP_USER=lidy REMOTE_USER=lidy ./scripts/probe-gpus.sh
#   ./scripts/probe-gpus.sh -J peter -j lidy -u lidy
#
# Environment / flags (flags win):
#   JUMP_HOST / -J   Jump host alias or hostname (default: peter)
#   JUMP_USER / -j   User on jump host (default: lidy)
#   REMOTE_USER / -u User on GPU hosts (default: lidy)
#   CONNECT_TIMEOUT / -t   SSH ConnectTimeout seconds (default: 8)
#   OUT_DIR / -o     Output directory (default: results/)
#   PARALLEL / -p    Max concurrent probes (default: 8)
#   --hosts SPEC     Subset, e.g. 01,05,10-12 or gpu03,gpu07
#
# Notes:
#   - Hostnames gpu01..gpu30 resolve on lab DNS (*.lrlab) when routing through
#     peter / the lab network (peter ≈ 192.168.0.254; gpu01–29 ≈ 192.168.0.21–68;
#     gpu30 ≈ 192.168.0.252). They do not resolve from the public internet alone.
#   - Requires working SSH agent/keys for BatchMode (no password prompts).
#   - Typical form: ssh -J lidy@peter -o BatchMode=yes lidy@gpuNN "nvidia-smi ..."
#   - Writes markdown + JSON under results/ (gitignored). Do not commit secrets/keys.
#
# Deps: bash, OpenSSH client, remote nvidia-smi. No extra packages.

set -euo pipefail

JUMP_HOST="${JUMP_HOST:-peter}"
JUMP_USER="${JUMP_USER:-lidy}"
REMOTE_USER="${REMOTE_USER:-lidy}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-8}"
OUT_DIR="${OUT_DIR:-results}"
PARALLEL="${PARALLEL:-8}"
HOST_SPEC=""

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

json_escape() {
  # Escape a string for JSON (no surrounding quotes).
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

parse_host_spec() {
  local spec=$1 part start end i h
  local -a out=()
  IFS=',' read -ra parts <<< "$spec"
  for part in "${parts[@]}"; do
    part="$(trim "$part")"
    if [[ $part =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start=$((10#${BASH_REMATCH[1]}))
      end=$((10#${BASH_REMATCH[2]}))
      if ((start > end)); then
        echo "error: invalid range $part" >&2
        exit 2
      fi
      for ((i = start; i <= end; i++)); do
        printf -v h '%02d' "$i"
        out+=("gpu${h}")
      done
    elif [[ $part =~ ^gpu([0-9]+)$ ]]; then
      printf -v h '%02d' "$((10#${BASH_REMATCH[1]}))"
      out+=("gpu${h}")
    elif [[ $part =~ ^([0-9]+)$ ]]; then
      printf -v h '%02d' "$((10#${BASH_REMATCH[1]}))"
      out+=("gpu${h}")
    else
      echo "error: bad host token: $part" >&2
      exit 2
    fi
  done
  printf '%s\n' "${out[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    -J|--jump-host) JUMP_HOST=$2; shift 2 ;;
    -j|--jump-user) JUMP_USER=$2; shift 2 ;;
    -u|--remote-user) REMOTE_USER=$2; shift 2 ;;
    -t|--timeout) CONNECT_TIMEOUT=$2; shift 2 ;;
    -o|--out-dir) OUT_DIR=$2; shift 2 ;;
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

mkdir -p "$OUT_DIR"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
MD_OUT="${OUT_DIR}/gpu-probe-${STAMP}.md"
JSON_OUT="${OUT_DIR}/gpu-probe-${STAMP}.json"
LATEST_MD="${OUT_DIR}/gpu-probe-latest.md"
LATEST_JSON="${OUT_DIR}/gpu-probe-latest.json"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/probe-gpus.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT

PROXY_JUMP="${JUMP_USER}@${JUMP_HOST}"

REMOTE_CMD=$(cat <<'EOS'
set +e
hostname_f=$(hostname -f 2>/dev/null || hostname)
who=$(whoami)
date_u=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if ! command -v nvidia-smi >/dev/null 2>&1; then
  printf 'STATUS=no_nvidia_smi\nHOST=%s\nUSER=%s\nTIME=%s\n' "$hostname_f" "$who" "$date_u"
  exit 0
fi
gpus=$(nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>/dev/null)
proc=$(nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits 2>/dev/null)
idx_map=$(nvidia-smi --query-gpu=index,uuid --format=csv,noheader,nounits 2>/dev/null)
# Best-effort: map PIDs to usernames for "who is using"
ps_map=""
if [[ -n $proc ]]; then
  while IFS=',' read -r _uuid _pid _rest; do
    _pid=$(echo "$_pid" | tr -d ' ')
    [[ -z $_pid || $_pid == \[N/A\] ]] && continue
    _user=$(ps -o user= -p "$_pid" 2>/dev/null | tr -d ' ')
    [[ -n $_user ]] && ps_map+="${_pid}=${_user}"$'\n'
  done <<< "$proc"
fi
printf 'STATUS=ok\nHOST=%s\nUSER=%s\nTIME=%s\n---GPUS---\n%s\n---PROCS---\n%s\n---IDX---\n%s\n---OWNERS---\n%s' \
  "$hostname_f" "$who" "$date_u" "$gpus" "$proc" "$idx_map" "$ps_map"
EOS
)

probe_one() {
  local host=$1
  local raw_file=${TMP_DIR}/${host}.raw
  local err_file=${TMP_DIR}/${host}.err
  local meta_file=${TMP_DIR}/${host}.meta
  local rc=0
  local ssh_base=(
    ssh
    -J "$PROXY_JUMP"
    -o BatchMode=yes
    -o ConnectTimeout="$CONNECT_TIMEOUT"
    -o StrictHostKeyChecking=accept-new
    -o ConnectionAttempts=1
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=1
  )

  if "${ssh_base[@]}" "${REMOTE_USER}@${host}" "$REMOTE_CMD" >"$raw_file" 2>"$err_file"; then
    rc=0
  else
    rc=$?
  fi
  printf 'host=%s\nrc=%s\n' "$host" "$rc" >"$meta_file"
}

echo "Probing ${#HOSTS[@]} host(s) via ${PROXY_JUMP} as ${REMOTE_USER}@gpuNN (timeout=${CONNECT_TIMEOUT}s, parallel=${PARALLEL})"

running=0
for host in "${HOSTS[@]}"; do
  probe_one "$host" &
  running=$((running + 1))
  if ((running >= PARALLEL)); then
    wait -n 2>/dev/null || true
    # Recompute running jobs (portable-ish)
    running=$(jobs -pr | wc -l | tr -d ' ')
  fi
done
wait

reachable=0
unreachable=0
free_gpus=0
used_gpus=0

{
  echo "# GPU probe ${STAMP}"
  echo
  echo "- Jump: \`${PROXY_JUMP}\`"
  echo "- Remote user: \`${REMOTE_USER}\`"
  echo "- ConnectTimeout: ${CONNECT_TIMEOUT}s"
  echo "- Hosts probed: ${#HOSTS[@]} (gpu01–gpu30 resolve via peter/lab DNS only)"
  echo
  echo "| Host | Reachable | Free/Used/Total | Who / what |"
  echo "|---|---|---|---|"
} >"$MD_OUT"

json_hosts_file=${TMP_DIR}/hosts.jsonl
: >"$json_hosts_file"

for host in "${HOSTS[@]}"; do
  meta=${TMP_DIR}/${host}.meta
  raw=${TMP_DIR}/${host}.raw
  err=${TMP_DIR}/${host}.err
  rc=$(sed -n 's/^rc=//p' "$meta" 2>/dev/null || echo 255)

  if [[ $rc != 0 ]]; then
    unreachable=$((unreachable + 1))
    err_snip=$(tr '\n' ' ' <"$err" 2>/dev/null | head -c 160 || true)
    err_snip_md=${err_snip//|/\\|}
    echo "| ${host} | no | — | SSH failed (rc=${rc}) ${err_snip_md} |" >>"$MD_OUT"
    printf '{"host":"%s","reachable":false,"rc":%s,"error":"%s"}\n' \
      "$host" "$rc" "$(json_escape "$err_snip")" >>"$json_hosts_file"
    continue
  fi

  reachable=$((reachable + 1))
  status=$(sed -n 's/^STATUS=//p' "$raw" | head -1)
  rhost=$(sed -n 's/^HOST=//p' "$raw" | head -1)
  ruser=$(sed -n 's/^USER=//p' "$raw" | head -1)
  rtime=$(sed -n 's/^TIME=//p' "$raw" | head -1)

  if [[ $status != ok ]]; then
    echo "| ${host} | yes | — | reachable; ${status:-unknown} (${rhost}, as ${ruser}) |" >>"$MD_OUT"
    printf '{"host":"%s","reachable":true,"status":"%s","remote_host":"%s","remote_user":"%s","time":"%s","gpus":[],"processes":[]}\n' \
      "$host" "$(json_escape "${status:-unknown}")" "$(json_escape "$rhost")" \
      "$(json_escape "$ruser")" "$(json_escape "$rtime")" >>"$json_hosts_file"
    continue
  fi

  gpus_block=$(awk '/^---GPUS---$/{f=1;next}/^---PROCS---$/{f=0}f' "$raw")
  procs_block=$(awk '/^---PROCS---$/{f=1;next}/^---IDX---$/{f=0}f' "$raw")
  idx_block=$(awk '/^---IDX---$/{f=1;next}/^---OWNERS---$/{f=0}f' "$raw")
  owners_block=$(awk '/^---OWNERS---$/{f=1;next}f' "$raw")

  declare -A pid_owner=()
  while IFS= read -r oline || [[ -n $oline ]]; do
    [[ -z ${oline// } ]] && continue
    if [[ $oline =~ ^([0-9]+)=(.*)$ ]]; then
      pid_owner[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    fi
  done <<<"$owners_block"

  declare -A uuid_to_idx=()
  while IFS= read -r iline || [[ -n $iline ]]; do
    [[ -z ${iline// } ]] && continue
    IFS=',' read -r ii iu <<<"$iline"
    ii=$(trim "$ii")
    iu=$(trim "$iu")
    uuid_to_idx[$iu]=$ii
  done <<<"$idx_block"

  total=0
  free=0
  used=0
  gpu_json_items=()
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z ${line// } ]] && continue
    IFS=',' read -r gidx gname mem_used mem_total util <<<"$line"
    gidx=$(trim "$gidx")
    gname=$(trim "$gname")
    mem_used=$(trim "$mem_used")
    mem_total=$(trim "$mem_total")
    util=$(trim "$util")
    # nvidia-smi may print [N/A]
    [[ $mem_used == \[N/A\] ]] && mem_used=0
    [[ $util == \[N/A\] ]] && util=0
    total=$((total + 1))
    state=used
    if [[ ${util:-0} =~ ^[0-9]+$ && ${mem_used:-0} =~ ^[0-9]+$ ]] \
      && ((util == 0 && mem_used < 50)); then
      free=$((free + 1))
      free_gpus=$((free_gpus + 1))
      state=free
    else
      used=$((used + 1))
      used_gpus=$((used_gpus + 1))
    fi
    gname_j=$(json_escape "$gname")
    gpu_json_items+=("{\"index\":${gidx:-0},\"name\":\"${gname_j}\",\"memory_used_mib\":${mem_used:-0},\"memory_total_mib\":${mem_total:-0},\"util_gpu\":${util:-0},\"state\":\"${state}\"}")
  done <<<"$gpus_block"

  proc_json_items=()
  proc_notes=()
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z ${line// } ]] && continue
    IFS=',' read -r guuid pid pname used_mem <<<"$line"
    guuid=$(trim "$guuid")
    pid=$(trim "$pid")
    pname=$(trim "$pname")
    used_mem=$(trim "$used_mem")
    [[ $used_mem == \[N/A\] ]] && used_mem=0
    gindex=${uuid_to_idx[$guuid]:-}
    owner=${pid_owner[$pid]:-unknown}
    proc_notes+=("gpu${gindex:-?}: ${owner} pid=${pid} ${pname} (${used_mem} MiB)")
    gindex_json=${gindex:-null}
    owner_j=$(json_escape "$owner")
    pname_j=$(json_escape "$pname")
    proc_json_items+=("{\"gpu_index\":${gindex_json},\"pid\":${pid:-0},\"user\":\"${owner_j}\",\"process_name\":\"${pname_j}\",\"used_gpu_memory_mib\":${used_mem:-0}}")
  done <<<"$procs_block"

  notes=ok
  if ((${#proc_notes[@]} > 0)); then
    printf -v notes '%s; ' "${proc_notes[@]}"
    notes=${notes%; }
    notes=${notes//|/\\|}
  elif ((free == total && total > 0)); then
    notes='all free'
  elif ((total == 0)); then
    notes='no GPUs reported'
  fi

  echo "| ${host} | yes | ${free}/${used}/${total} | ${notes} |" >>"$MD_OUT"

  gpus_json='[]'
  if ((${#gpu_json_items[@]} > 0)); then
    gpus_json="[$(IFS=,; echo "${gpu_json_items[*]}")]"
  fi
  procs_json='[]'
  if ((${#proc_json_items[@]} > 0)); then
    procs_json="[$(IFS=,; echo "${proc_json_items[*]}")]"
  fi

  printf '{"host":"%s","reachable":true,"status":"ok","remote_host":"%s","remote_user":"%s","time":"%s","summary":{"free":%d,"used":%d,"total":%d},"gpus":%s,"processes":%s}\n' \
    "$host" "$(json_escape "$rhost")" "$(json_escape "$ruser")" "$(json_escape "$rtime")" \
    "$free" "$used" "$total" "$gpus_json" "$procs_json" >>"$json_hosts_file"

  unset pid_owner uuid_to_idx
done

{
  echo
  echo "## Summary"
  echo
  echo "- Reachable: **${reachable}** / ${#HOSTS[@]}"
  echo "- Unreachable: **${unreachable}**"
  echo "- GPUs free / used (reachable hosts with nvidia-smi): **${free_gpus}** / **${used_gpus}**"
  echo
  echo "## Per-host raw"
  echo
} >>"$MD_OUT"

for host in "${HOSTS[@]}"; do
  raw=${TMP_DIR}/${host}.raw
  meta=${TMP_DIR}/${host}.meta
  rc=$(sed -n 's/^rc=//p' "$meta" 2>/dev/null || echo 255)
  echo "### ${host}" >>"$MD_OUT"
  echo >>"$MD_OUT"
  echo '```' >>"$MD_OUT"
  if [[ $rc != 0 ]]; then
    cat "${TMP_DIR}/${host}.err" >>"$MD_OUT" 2>/dev/null || true
  else
    cat "$raw" >>"$MD_OUT"
  fi
  echo '```' >>"$MD_OUT"
  echo >>"$MD_OUT"
done

{
  echo '{'
  printf '  "stamp": "%s",\n' "$STAMP"
  printf '  "jump": "%s",\n' "$PROXY_JUMP"
  printf '  "remote_user": "%s",\n' "$REMOTE_USER"
  printf '  "connect_timeout": %s,\n' "$CONNECT_TIMEOUT"
  printf '  "summary": {"reachable": %d, "unreachable": %d, "gpus_free": %d, "gpus_used": %d, "hosts": %d},\n' \
    "$reachable" "$unreachable" "$free_gpus" "$used_gpus" "${#HOSTS[@]}"
  echo '  "hosts": ['
  host_count=$(wc -l <"$json_hosts_file" | tr -d ' ')
  i=0
  while IFS= read -r line; do
    i=$((i + 1))
    if ((i < host_count)); then
      echo "    ${line},"
    else
      echo "    ${line}"
    fi
  done <"$json_hosts_file"
  echo '  ]'
  echo '}'
} >"$JSON_OUT"

cp "$MD_OUT" "$LATEST_MD"
cp "$JSON_OUT" "$LATEST_JSON"

echo
echo "Wrote:"
echo "  $MD_OUT"
echo "  $JSON_OUT"
echo "  $LATEST_MD"
echo "  $LATEST_JSON"
echo "Reachable ${reachable}/${#HOSTS[@]}; GPUs free/used ${free_gpus}/${used_gpus}"
