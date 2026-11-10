#!/usr/bin/env python3
"""Render one DRA-allocated diagnostic pod per eligible RDMA worker."""
import argparse
import json
import re
import sys


def is_ready(node):
    return any(c.get("type") == "Ready" and c.get("status") == "True"
               for c in node.get("status", {}).get("conditions", []))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--nodes-json", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--namespace", default="rdma-workloads")
    parser.add_argument("--device-class", default="dra.net")
    parser.add_argument("--interface", default="ens800f0np0")
    args = parser.parse_args()

    run_id = re.sub(r"[^a-z0-9-]", "-", args.run_id.lower()).strip("-")
    if not run_id or len(run_id) > 20:
        parser.error("--run-id must sanitize to 1–20 lowercase alphanumeric/hyphen characters")

    cluster_nodes = json.load(open(args.nodes_json, encoding="utf-8"))
    candidates = [n for n in cluster_nodes.get("items", [])
                 if n.get("metadata", {}).get("labels", {}).get("oci-rdma") == "true"
                 and n.get("metadata", {}).get("labels", {}).get("oke-rdma-mode") == "dranet"]
    ready = [n for n in candidates if is_ready(n)]
    skipped = [n.get("metadata", {}).get("name", "unknown") for n in candidates if not is_ready(n)]
    if len(ready) < 2:
        parser.error(f"need at least two Ready DRANET nodes; found {len(ready)} (not Ready: {skipped})")

    items = []
    inventory = {"run_id": run_id, "ready_nodes": [], "not_ready_nodes": skipped}
    selector_expr = (
        'device.driver == "dra.net" && '
        'has(device.attributes["dra.net"].ifName) && '
        f'device.attributes["dra.net"].ifName == "{args.interface}" && '
        'device.attributes["dra.net"].rdma == true'
    )
    for index, node in enumerate(sorted(ready, key=lambda x: x["metadata"]["name"])):
        metadata = node["metadata"]
        node_name = metadata["name"]
        hostname = metadata.get("labels", {}).get("kubernetes.io/hostname")
        if not hostname:
            parser.error(f"node {node_name} has no kubernetes.io/hostname label")
        pod_name = f"rdma-pair-{run_id}-{index:03d}"
        claim_name = pod_name
        inventory["ready_nodes"].append({"node": node_name, "hostname": hostname,
                                          "pod": pod_name, "claim": claim_name})
        items.extend([
            {"apiVersion": "resource.k8s.io/v1", "kind": "ResourceClaim",
             "metadata": {"name": claim_name, "namespace": args.namespace,
                          "labels": {"rdma-pair-run": run_id}},
             "spec": {"devices": {"requests": [{"name": "rdma", "exactly": {
                 "deviceClassName": args.device_class,
                 "selectors": [{"cel": {"expression": selector_expr}}]}}]}}},
            {"apiVersion": "v1", "kind": "Pod",
             "metadata": {"name": pod_name, "namespace": args.namespace,
                          "labels": {"app": "rdma-pair-check", "rdma-pair-run": run_id}},
             "spec": {
                 "restartPolicy": "Never", "automountServiceAccountToken": False,
                 "nodeSelector": {"oci-rdma": "true", "oke-rdma-mode": "dranet",
                                  "kubernetes.io/hostname": hostname},
                 "resourceClaims": [{"name": "rdma", "resourceClaimName": claim_name}],
                 "imagePullSecrets": [{"name": "ocir-pull"}],
                 "containers": [{
                     "name": "tools", "image": args.image, "imagePullPolicy": "IfNotPresent",
                     "command": ["sleep", "infinity"],
                     "securityContext": {"allowPrivilegeEscalation": False,
                                          "capabilities": {"drop": ["ALL"], "add": ["IPC_LOCK"]}},
                     "resources": {"requests": {"cpu": "100m", "memory": "256Mi"},
                                   "limits": {"memory": "1Gi"},
                                   "claims": [{"name": "rdma"}]},
                 }],
             }},
        ])

    json.dump(inventory, sys.stderr, indent=2)
    sys.stderr.write("\n")
    json.dump({"apiVersion": "v1", "kind": "List", "items": items}, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
