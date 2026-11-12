# code_collection

Code collections

## GPU probe

Find free GPUs on `gpu01`–`gpu30`. **Run on peter** (lab network):

```bash
./scripts/probe-gpus.sh
```

SSHs directly to each host as your user (default `$USER`, else `lidy`), checks `nvidia-smi`, and writes free GPUs to:

```text
results/available-gpus.txt
```

Optional: `./scripts/probe-gpus.sh -u lidy` or `--hosts 01,05,10-12`. Output path is gitignored (`results/`).
