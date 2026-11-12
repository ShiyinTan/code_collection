# code_collection

Code collections

## GPU probe (gpu01–gpu30 via peter)

Probe lab GPU servers through the SSH jump host `peter` (`peter.pi.titech.ac.jp` / lab `192.168.0.254`). Hostnames `gpu01`…`gpu30` resolve on lab DNS (`*.lrlab`) when you route via peter; they are not reachable from the public internet alone.

```bash
./scripts/probe-gpus.sh
```

Defaults: jump user `lidy`, remote user `lidy`, hosts `gpu01`–`gpu30`. Overrides:

```bash
./scripts/probe-gpus.sh -J peter -j lidy -u lidy
./scripts/probe-gpus.sh --hosts 01,05,10-12
JUMP_USER=lidy REMOTE_USER=other ./scripts/probe-gpus.sh
```

Requires SSH agent/keys (BatchMode; no password prompts). Writes markdown + JSON under `results/` (gitignored). Needs only bash, OpenSSH, and remote `nvidia-smi`.
