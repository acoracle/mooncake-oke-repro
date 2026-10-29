#!/usr/bin/env bash
# Copy an existing image pull secret without printing its credential data.
set -euo pipefail
SOURCE_NAMESPACE=${SOURCE_NAMESPACE:-rdma-test}
SOURCE_SECRET=${SOURCE_SECRET:-ocir-pull}
TARGET_NAMESPACE=${TARGET_NAMESPACE:-mooncake}
TARGET_SECRET=${TARGET_SECRET:-ocir-pull}
kubectl get namespace "$TARGET_NAMESPACE" >/dev/null
kubectl -n "$SOURCE_NAMESPACE" get secret "$SOURCE_SECRET" -o json |
  python3 -c 'import json,sys; s=json.load(sys.stdin); print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":sys.argv[1],"namespace":sys.argv[2]},"type":s["type"],"data":s["data"]}))' "$TARGET_SECRET" "$TARGET_NAMESPACE" |
  kubectl apply -f -
echo "Copied $SOURCE_NAMESPACE/$SOURCE_SECRET to $TARGET_NAMESPACE/$TARGET_SECRET (credential contents were not displayed)."
