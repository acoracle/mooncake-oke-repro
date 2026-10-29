#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
IMAGE=${IMAGE:?Set IMAGE to the vLLM Mooncake image in OCIR}
NODE=${NODE:?Set NODE to the worker hostname/IP for the vLLM pod}
OWNER=${OWNER:?Set OWNER to a reachable Mooncake owner host:port}
PROTOCOL=${PROTOCOL:-tcp}
DEVICE_NAME=${DEVICE_NAME:-mlx5_2}
kubectl -n mooncake rollout status deployment/mooncake-master --timeout=180s
kubectl -n mooncake rollout status daemonset/mooncake-storage --timeout=180s
kubectl -n mooncake get secret ocir-pull >/dev/null
# Node labels are checked rather than assuming the IP is the hostname label.
HOST_LABEL=$(kubectl get node "$NODE" -o jsonpath='{.metadata.labels.kubernetes\.io/hostname}')
test -n "$HOST_LABEL"
if ! test -s model-revision.txt; then
  curl -fsS https://huggingface.co/api/models/Qwen/Qwen2.5-0.5B-Instruct |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])' > model-revision.txt
fi
MODEL_REVISION=$(cat model-revision.txt)
kubectl -n mooncake create configmap vllm-mooncake-scripts \
  --from-file=request.py --dry-run=client -o yaml | kubectl apply -f -
if [[ "$PROTOCOL" == rdma ]]; then NODES=${RDMA_NODES:-"$(kubectl get nodes -l oci-rdma=true -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')"} bash rdma-preflight.sh; fi
python3 render.py --image "$IMAGE" --node "$HOST_LABEL" --owner "$OWNER" --protocol "$PROTOCOL" \
  --device-name "$DEVICE_NAME" --model-revision "$MODEL_REVISION" > vllm.json
kubectl apply --dry-run=server -f vllm.json
kubectl apply -f vllm.json
kubectl -n mooncake rollout status deployment/vllm-mooncake --timeout=1800s
kubectl -n mooncake logs deployment/vllm-mooncake --tail=100
