#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
SEED=${SEED:-$(date +%s)}
OUTPUT_TOKENS=${OUTPUT_TOKENS:-128}
CONCURRENCY=${CONCURRENCY:-1}
OUT="benchmark-$SEED-$OUTPUT_TOKENS-$CONCURRENCY"
mkdir -p "$OUT"
run() {
  local phase=$1
  local tokenizer
  tokenizer=$(kubectl -n mooncake exec deployment/vllm-mooncake -- python3 -c '
from pathlib import Path
from huggingface_hub import snapshot_download
revision = Path("/etc/mooncake/model-revision").read_text().strip()
print(snapshot_download("Qwen/Qwen2.5-0.5B-Instruct", revision=revision, local_files_only=True))
')
  kubectl -n mooncake exec deployment/vllm-mooncake -- mkdir -p /tmp/mooncake-bench
  kubectl -n mooncake exec deployment/vllm-mooncake -- \
    vllm bench serve --backend openai --base-url http://127.0.0.1:8000 \
    --model cpu-test --tokenizer "$tokenizer" \
    --dataset-name random --random-input-len 4096 \
    --random-output-len "$OUTPUT_TOKENS" --random-range-ratio 0 \
    --num-prompts 32 --max-concurrency "$CONCURRENCY" --request-rate inf \
    --seed "$SEED" --ignore-eos --num-warmups 0 \
    --percentile-metrics ttft,tpot,e2el --metric-percentiles 50,95,99 \
    --save-result --save-detailed --result-dir /tmp/mooncake-bench \
    --result-filename "$phase.json" 2>&1 | tee "$OUT/$phase.log"
  kubectl -n mooncake exec deployment/vllm-mooncake -- \
    cat "/tmp/mooncake-bench/$phase.json" > "$OUT/$phase.json"
}
run cold
kubectl -n mooncake rollout restart deployment/vllm-mooncake
kubectl -n mooncake rollout status deployment/vllm-mooncake --timeout=1800s
run warm
kubectl -n mooncake logs deployment/vllm-mooncake > "$OUT/warm-vllm.log"
python3 - "$OUT" <<'PY'
import json, pathlib, re, sys
out = pathlib.Path(sys.argv[1])
for phase in ['cold', 'warm']:
    result = json.loads((out / f'{phase}.json').read_text())
    print(phase.upper())
    for key, value in result.items():
        if key in ('completed', 'failed', 'duration') or (
            key.startswith(('mean_', 'median_', 'p95_', 'p99_'))
            and any(x in key for x in ('ttft', 'tpot', 'e2el'))
        ) or 'throughput' in key:
            print(f'  {key}: {value}')
    if result.get('failed', 0):
        sys.exit('Some benchmark requests failed; do not interpret throughput yet.')
log = (out / 'warm-vllm.log').read_text()
loads = [line for line in log.splitlines() if 'Mooncake load tier summary:' in line]
if not any(re.search(r'success_keys=[1-9][0-9]*', line) for line in loads):
    sys.exit('NOT PROVEN: warm run has no successful Mooncake load evidence.')
if any(re.search(r'failed_keys=[1-9][0-9]*', line) for line in loads):
    sys.exit('External loads failed. Inspect warm-vllm.log.')
print('Warm-run external Mooncake loads confirmed.')
PY
echo "Results saved in $OUT"
