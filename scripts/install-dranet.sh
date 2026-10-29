#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${DRANET_VERSION:-v1.5.0}
helm upgrade --install dranet \
  oci://registry.k8s.io/networking/charts/dranet \
  --version "$VERSION" --namespace kube-system \
  -f "$ROOT/k8s/dranet/values.yaml"
kubectl apply -f "$ROOT/k8s/dranet/namespaces.yaml"
kubectl apply --dry-run=server -f "$ROOT/k8s/dranet/deviceclass.yaml"
kubectl apply -f "$ROOT/k8s/dranet/deviceclass.yaml"
kubectl -n kube-system rollout status daemonset/dranet --timeout=300s
kubectl get nodes -L oci-rdma,oke-rdma-mode
kubectl get deviceclasses
kubectl get resourceslices -o wide
