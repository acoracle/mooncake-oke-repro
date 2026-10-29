#!/usr/bin/env bash
# Build and push requested images to OCIR. Password is prompted by podman/docker.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ENGINE=${ENGINE:-podman}
REGISTRY=${REGISTRY:-fra.ocir.io}
OCIR_NAMESPACE=${OCIR_NAMESPACE:?Set OCIR_NAMESPACE to your tenancy namespace}
TAG=${TAG:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo local)}
OCIR_USERNAME=${OCIR_USERNAME:-}
PODMAN_CONFIG=${PODMAN_CONFIG:-${OCIR_AUTH_DIR:-}}
ENGINE_ARGS=()
if [[ "$ENGINE" == podman && -n "$PODMAN_CONFIG" ]]; then ENGINE_ARGS+=(--config "$PODMAN_CONFIG"); fi
BUILD_VLLM=${BUILD_VLLM:-0}
BUILD_RDMA_TOOLS=${BUILD_RDMA_TOOLS:-1}

command -v "$ENGINE" >/dev/null || { echo "Container engine not found: $ENGINE" >&2; exit 1; }
if [[ ${SKIP_LOGIN:-0} != 1 ]]; then
  [[ -n "$OCIR_USERNAME" ]] || { echo 'Set OCIR_USERNAME (tenancy/identity-domain/user) or SKIP_LOGIN=1 if already authenticated.' >&2; exit 1; }
  "$ENGINE" "${ENGINE_ARGS[@]}" login "$REGISTRY" --username "$OCIR_USERNAME"
fi

build_push() {
  local name=$1 context=$2
  local image="$REGISTRY/$OCIR_NAMESPACE/$name:$TAG"
  echo "Building $image"
  "$ENGINE" "${ENGINE_ARGS[@]}" build --platform linux/amd64 -t "$image" -f "$context/Dockerfile" "$context"
  "$ENGINE" "${ENGINE_ARGS[@]}" push "$image"
  echo "$image"
}
build_push mooncake-store "$ROOT/images/mooncake-store"
if [[ "$BUILD_RDMA_TOOLS" == 1 ]]; then
  build_push rdma-tools "$ROOT/images/rdma-tools"
fi
if [[ "$BUILD_VLLM" == 1 ]]; then
  build_push vllm-mooncake "$ROOT/images/vllm-mooncake"
fi
