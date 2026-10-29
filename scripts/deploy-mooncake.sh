#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${IMAGE:?Set IMAGE to the Mooncake Store image in OCIR}
PROTOCOL=${PROTOCOL:-tcp}
RAM_GIB=${RAM_GIB:-128}
DISK_BYTES=${DISK_BYTES:-3000000000000}
DEVICE_NAMES=${DEVICE_NAMES:-mlx5_2}
RENDER_ARGS=(--image "$IMAGE" --protocol "$PROTOCOL" --device-names "$DEVICE_NAMES" --ram-gib "$RAM_GIB" --disk-bytes "$DISK_BYTES")
if [[ ${AUTO_PREPARE_NVME:-0} == 1 ]]; then
  echo 'NVMe auto-preparation is ENABLED: blank /dev/nvme0n1 disks may be formatted on eligible workers.' >&2
  [[ ${CONFIRM_BLANK_NVME_FORMAT:-} == I_UNDERSTAND_EMPTY_DISKS_ONLY ]] || {
    echo 'Set CONFIRM_BLANK_NVME_FORMAT=I_UNDERSTAND_EMPTY_DISKS_ONLY to proceed.' >&2; exit 1;
  }
  RENDER_ARGS+=(--auto-prepare-nvme)
fi
kubectl get secret ocir-pull -n mooncake >/dev/null
python3 "$ROOT/k8s/mooncake/render.py" "${RENDER_ARGS[@]}" > "$ROOT/k8s/mooncake/rendered.yaml"
kubectl apply --dry-run=server -f "$ROOT/k8s/mooncake/rendered.yaml"
kubectl apply -f "$ROOT/k8s/mooncake/rendered.yaml"
kubectl -n mooncake rollout status deployment/mooncake-master --timeout=600s
kubectl -n mooncake rollout status daemonset/mooncake-storage --timeout=900s
kubectl -n mooncake get pods -o wide
