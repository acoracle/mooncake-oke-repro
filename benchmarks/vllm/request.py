"""One deterministic streaming request; run inside the vLLM pod."""
import argparse
import json
import os
import time
import requests

p = argparse.ArgumentParser()
p.add_argument("--run-id", required=True)
p.add_argument("--output-tokens", type=int, default=64)
a = p.parse_args()
prompt = (
    f"Validation dataset {a.run_id}. Read the following reference carefully.\n"
    + "A cache stores keys and values so repeated requests can reuse prior work.\n" * 200
    + "\nIn one paragraph, explain why reusing a cached prefix can save computation.\n"
)
base = "http://127.0.0.1:8000"
tokenized = requests.post(base + "/tokenize", json={"model": "cpu-test", "prompt": prompt}, timeout=60)
tokenized.raise_for_status()
input_tokens = tokenized.json()["count"]
assert input_tokens + a.output_tokens <= 8192, input_tokens
body = {"model": "cpu-test", "prompt": prompt, "max_tokens": a.output_tokens,
        "temperature": 0, "top_p": 1, "seed": 42, "repetition_penalty": 1,
        "stream": True, "stream_options": {"include_usage": True}}
start = time.perf_counter()
ttft = None
text = ""
usage = None
with requests.post(base + "/v1/completions", json=body, stream=True, timeout=(30, 600)) as response:
    response.raise_for_status()
    for line in response.iter_lines(chunk_size=1, decode_unicode=True):
        if not line or not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            break
        event = json.loads(data)
        if "error" in event:
            raise RuntimeError(event["error"])
        if event.get("usage"):
            usage = event["usage"]
        for choice in event.get("choices", []):
            fragment = choice.get("text", "")
            if fragment and ttft is None:
                ttft = time.perf_counter() - start
            text += fragment
elapsed = time.perf_counter() - start
assert text and ttft is not None, "No output text received"
print(json.dumps({"run_id": a.run_id, "input_tokens": input_tokens,
                  "protocol": json.load(open(os.environ["MOONCAKE_CONFIG_PATH"]))["protocol"],
                  "ttft_seconds": ttft, "e2e_seconds": elapsed,
                  "usage": usage, "text": text}, indent=2))
