#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
find "$ROOT" -type f -name '*.sh' -print0 | while IFS= read -r -d '' file; do bash -n "$file"; done
python3 -m py_compile \
  "$ROOT/k8s/mooncake/render.py" \
  "$ROOT/benchmarks/render-client-pods.py" \
  "$ROOT/scripts/render-rdma-pair-pods.py" \
  "$ROOT/benchmarks/vllm/render.py" \
  "$ROOT/benchmarks/vllm/preflight.py" \
  "$ROOT/benchmarks/vllm/request.py"
python3 - "$ROOT/scripts/render-rdma-pair-pods.py" <<'PY'
import json, subprocess, sys, tempfile
from pathlib import Path

nodes = {"items": []}
for name in ("worker-a", "worker-b"):
    nodes["items"].append({
        "metadata": {"name": name, "labels": {
            "oci-rdma": "true", "oke-rdma-mode": "dranet",
            "kubernetes.io/hostname": name,
        }},
        "status": {"conditions": [{"type": "Ready", "status": "True"}]},
    })
with tempfile.TemporaryDirectory() as temp:
    source = Path(temp) / "nodes.json"
    source.write_text(json.dumps(nodes))
    result = subprocess.run([
        sys.executable, sys.argv[1], "--nodes-json", str(source),
        "--image", "fra.ocir.io/example/rdma-tools:test", "--run-id", "validate",
    ], check=True, capture_output=True, text=True)
    inventory = json.loads(result.stderr)
    manifest = json.loads(result.stdout)
    assert len(inventory["ready_nodes"]) == 2
    assert len(manifest["items"]) == 4
    pods = [item for item in manifest["items"] if item["kind"] == "Pod"]
    claims = [item for item in manifest["items"] if item["kind"] == "ResourceClaim"]
    assert len(pods) == len(claims) == 2
    assert {p["spec"]["nodeSelector"]["kubernetes.io/hostname"] for p in pods} == {"worker-a", "worker-b"}
    assert all("rdma == true" in c["spec"]["devices"]["requests"][0]["exactly"]["selectors"][0]["cel"]["expression"] for c in claims)
print("RDMA pair pod renderer validation passed.")
PY
python3 "$ROOT/benchmarks/vllm/render.py" --image example.invalid/lab/vllm:test \
  --node worker-a --owner 10.0.0.1:50053 --protocol rdma \
  --model-revision 7ae557604adf67be50417f59c2c2f167def9a775 > /tmp/vllm-rdma-render.json
python3 "$ROOT/k8s/mooncake/render.py" --image example.invalid/lab/mooncake-store:test --protocol tcp > /tmp/mooncake-tcp-render.json
python3 "$ROOT/k8s/mooncake/render.py" --image example.invalid/lab/mooncake-store:test --protocol rdma --auto-prepare-nvme > /tmp/mooncake-rdma-render.json
python3 - <<'PY'
import json
for path, protocol in [('/tmp/mooncake-tcp-render.json', 'tcp'), ('/tmp/mooncake-rdma-render.json', 'rdma')]:
    doc=json.load(open(path))
    ds=next(x for x in doc['items'] if x['kind']=='DaemonSet')
    pod=ds['spec']['template']['spec']
    store=pod['containers'][0]
    command=store['args'][0]
    assert f'--protocol="$MOONCAKE_PROTOCOL"' in command
    assert f"'name': 'MOONCAKE_PROTOCOL'" not in command
    assert any(e['name']=='MOONCAKE_PROTOCOL' and e['value']==protocol for e in store['env'])
    if protocol == 'rdma':
        assert store['securityContext']['privileged'] is True
        assert any(v['name']=='infiniband' for v in pod['volumes'])
    if path.endswith('rdma-render.json'):
        assert any(i['name']=='prepare-local-nvme' for i in pod['initContainers'])
vllm=json.load(open('/tmp/vllm-rdma-render.json'))
vpod=next(x for x in vllm['items'] if x['kind']=='Deployment')['spec']['template']['spec']
assert vpod['hostNetwork'] is True
assert vpod['containers'][0]['securityContext']['privileged'] is True
assert json.loads(next(x for x in vllm['items'] if x['kind']=='ConfigMap')['data']['config.json'])['protocol']=='rdma'
print('Rendered TCP/RDMA Store and vLLM manifests and syntax checks passed.')
PY
rm -f /tmp/mooncake-tcp-render.json /tmp/mooncake-rdma-render.json /tmp/vllm-rdma-render.json
