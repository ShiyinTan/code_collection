# code_collection

Code collections

## GPU probe

List hosts among `gpu01`–`gpu30` that have **at least one free GPU**. **Run on peter**:

```bash
./scripts/probe-gpus.sh
```

- Free GPU = no nvidia compute process on that device (partially busy servers still count if any GPU is free).
- `results/available-hosts.txt` — hostnames only, one per line (e.g. `gpu03`)
- `results/gpu-status.txt` — reachable / skipped reasons (unreachable, fully busy, …)

Optional: `./scripts/probe-gpus.sh -u lidy` or `--hosts 01,05,10-12`. `results/` is gitignored.
