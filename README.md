# code_collection

Code collections

## GPU probe

List `gpu01`–`gpu30` hosts that have GPUs. **Run on peter**:

```bash
./scripts/probe-gpus.sh
```

- Includes a host if `nvidia-smi` reports ≥1 GPU (busy or free — no idle filter).
- Skips unreachable hosts and hosts with no GPU / no `nvidia-smi`.
- `results/available-hosts.txt` — hostnames only, one per line
- `results/gpu-status.txt` — included / skipped reasons
- Probe SSH ignores `known_hosts` (`StrictHostKeyChecking=no`) so changed lab host keys do not fail BatchMode.

Optional: `./scripts/probe-gpus.sh -u lidy` or `--hosts 01,05,10-12`. `results/` is gitignored.

If you prefer to keep strict host-key checks for interactive SSH, purge a stale entry instead, e.g.:

```bash
ssh-keygen -R gpu01 -R 192.168.0.21
```
