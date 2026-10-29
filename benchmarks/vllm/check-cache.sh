#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
RUN_ID=${RUN_ID:-"external-kv-$(date +%s)"}
OUT="results-$RUN_ID"
mkdir -p "$OUT"
kubectl -n mooncake rollout status deployment/vllm-mooncake --timeout=1800s
kubectl -n mooncake exec deployment/vllm-mooncake -- \
  python3 /scripts/request.py --run-id "$RUN_ID" > "$OUT/cold.json"
# Keep the same Store owners/master and cache namespace. Only vLLM restarts.
kubectl -n mooncake rollout restart deployment/vllm-mooncake
kubectl -n mooncake rollout status deployment/vllm-mooncake --timeout=1800s
kubectl -n mooncake exec deployment/vllm-mooncake -- \
  python3 /scripts/request.py --run-id "$RUN_ID" > "$OUT/warm.json"
kubectl -n mooncake logs deployment/vllm-mooncake > "$OUT/warm-vllm.log"
kubectl -n mooncake exec deployment/vllm-mooncake -- python3 -c \
  'import requests; r=requests.get("http://127.0.0.1:8000/metrics"); r.raise_for_status(); print(r.text)' \
  > "$OUT/metrics.txt"
python3 - "$OUT" <<'PY'
import json, pathlib, re, sys
out = pathlib.Path(sys.argv[1])
cold, warm = [json.loads((out / f'{name}.json').read_text()) for name in ('cold', 'warm')]
for name, result in [('cold', cold), ('warm', warm)]:
    print(f"{name}: input={result['input_tokens']} tokens, TTFT={result['ttft_seconds']:.3f}s, "
          f"end-to-end={result['e2e_seconds']:.3f}s")
if cold['text'] != warm['text']:
    sys.exit('FAIL: deterministic cold/warm outputs differ. Do not benchmark yet; inspect correctness.')
print('Deterministic output matches across the vLLM restart.')
log = (out / 'warm-vllm.log').read_text()
lines = [line for line in log.splitlines() if 'Mooncake load tier summary:' in line]
for line in lines:
    print(line)
if not any(re.search(r'success_keys=[1-9][0-9]*', line) for line in lines):
    sys.exit('NOT PROVEN: no successful external Mooncake load found. Inspect warm-vllm.log.')
if any(re.search(r'failed_keys=[1-9][0-9]*', line) for line in lines):
    sys.exit('FAIL: an external load reported failed keys.')
print('PASS: external Mooncake blocks loaded after vLLM restarted; local prefix-cache reuse cannot explain this.')
(out / (warm['protocol'] + '-external-cache-proven')).write_text('passed\n')
print('This is an integration smoke test, not a statistically stable performance benchmark.')
PY
echo "Evidence saved in $OUT"
