# code_collection

Code collections

## GPU probe

Run on a lab host that can SSH to the GPUs (peter or a gpuNN box). First list hosts that have GPUs, then find which cards are free:

```bash
./scripts/probe-gpus.sh
./scripts/find-free-gpus.sh
```

### Quick aliases (no `cd`)

Point aliases at absolute script paths. Outputs always go under the **repo** `results/` (not `$PWD`):

```bash
# put in ~/.bashrc — set REPO to your clone
REPO=/path/to/code_collection
alias gpu-probe="$REPO/scripts/probe-gpus.sh"
alias gpu-free="$REPO/scripts/find-free-gpus.sh"
```

Then from any directory:

```bash
gpu-probe
gpu-free
```

### `probe-gpus.sh`

- Includes a host if `nvidia-smi` reports ≥1 GPU (busy or free — no idle filter).
- Skips unreachable hosts and hosts with no GPU / no `nvidia-smi`.
- `results/available-hosts.txt` — hostnames only, one per line
- `results/gpu-status.txt` — included / skipped reasons

### `find-free-gpus.sh`

- Reads `results/available-hosts.txt` (run probe first).
- Free GPU = no nvidia compute process on that device.
- `results/free-gpus.txt` — one line per free card with index, model, and VRAM, e.g. `gpu03:0  NVIDIA GeForce RTX 3090  24200/24564 MiB` (`free/total`); also printed on stdout.

Both scripts use BatchMode SSH and ignore `known_hosts` for lab key churn. Optional: `-u lidy`. `results/` is gitignored.

If you prefer strict host-key checks for interactive SSH, purge a stale entry instead, e.g.:

```bash
ssh-keygen -R gpu01 -R 192.168.0.21
```
