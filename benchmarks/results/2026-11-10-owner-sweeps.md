# Mooncake Store owner-count sweeps on OKE workers

Run date: 2026-11-10 (UTC)

## First test: four owners

The first test used four Ready `BM.Optimized3.36` workers in AD-1. Eight independent clients ran across the four owners, two clients pinned to each worker. It used RDMA on `mlx5_2`, 30-second reads, and a 32 GiB total client working set backed by RAM replicas. It completed with zero failed objects, misses, or verification failures.

| Ready Mooncake owners | Clients | Aggregate read throughput | Failed objects | Misses | Verification failures |
|---:|---:|---:|---:|---:|---:|
| 4 | 8 | 25,171.1 MiB/s | 0 | 0 | 0 |

Client throughput ranged from 2,936.3 to 3,716.4 MiB/s. Per-client p50 latency ranged from 4.0 to 5.2 ms, p95 from 5.9 to 7.3 ms, and p99 from 9.1 to 10.5 ms. Raw results were saved on the bastion at `/home/opc/mooncake-oke-repro/benchmarks/results-20261110T111440Z-18649`.

To reproduce this point by itself, have exactly four Mooncake owners Ready, then run eight clients (two per owner):

```bash
OWNERS=4 CLIENTS_PER_OWNER=2 PROTOCOL=rdma DEVICE_NAME=mlx5_2 \
IMAGE="$STORE_IMAGE" bash benchmarks/scale-store.sh
```

## Later test: 1/2/3 owners

This sweep ran later, after only three workers were Ready. The nodepool remained configured for four workers, but only three worker instances were available for this sweep.

### Setup

- OKE cluster with three Ready `BM.Optimized3.36` workers labeled `oci-rdma=true`; all three had DRANET/RoCE enabled.
- The nodepool remained configured for four workers, but only three worker instances were available for this sweep.
- Mooncake Store image: `fra.ocir.io/fr9qm01oq44x/mooncake-store:5ac6dec`.
- Mooncake master: one Ready Deployment replica; storage: one Ready DaemonSet owner per selected worker.
- Owner and benchmark client transport: RDMA using `mlx5_2`; owner logs confirmed that device was available.
- No nodepool resize was performed for the sweep. The DaemonSet was temporarily restricted to 1, 2, then 3 of the existing Ready workers; its original selector was restored afterward.

## Workload and result

Each owner-count point used two independent benchmark clients per owner. Each client prepared 4,096 values of 1 MiB each (4 GiB) with unique keys, then ran a 30-second sequential `read_perf` phase. The benchmark used zero-copy I/O, batch size 16, 64-byte keys, one memory replica, and no DFS replica. Aggregate throughput is the sum of the clients' `read_perf` MiB/s values.

| Ready Mooncake owners | Clients | Aggregate read throughput | Failed objects | Misses | Verification failures |
|---:|---:|---:|---:|---:|---:|
| 1 | 2 | 8,106.4 MiB/s | 0 | 0 | 0 |
| 2 | 4 | 16,597.3 MiB/s | 0 | 0 | 0 |
| 3 | 6 | 21,227.0 MiB/s | 0 | 0 | 0 |

The two-owner result was 2.05× the one-owner result. Three owners reached 2.62× the one-owner throughput and 1.28× the two-owner result. The separate four-owner first test reached 3.10× the one-owner result and 18.6% above the later three-owner result. Since the four-owner point ran in a separate session, repeat all four counts in one controlled sweep before attributing the difference to adding the fourth owner. Throughput per owner for the later 1/2/3 sweep was about 8,106, 8,299, and 7,076 MiB/s. These are single observations, not a statistical comparison; rerun each point at least three times and compare medians and ranges.

## Reproduction

Follow the prerequisites, image build/push, DRANET, NVMe preparation, and Mooncake deployment steps in the main README. Ensure the owner DaemonSet and benchmark image are both configured for the same RDMA transport, all participating nodes are Ready, `mlx5_2` is active, and no old benchmark client pods remain. Set `STORE_IMAGE` to the full OCIR image reference, then run:

```bash
IMAGE="$STORE_IMAGE" \
OWNERS_SWEEP="1 2 3" \
CLIENTS_PER_OWNER=2 \
PROTOCOL=rdma \
DEVICE_NAME=mlx5_2 \
bash benchmarks/scale-store-same-pool.sh
```

The first four-owner test earlier on 2026-11-10 is documented above. The later 1/2/3 sweep used the same two-clients-per-owner workload on the available workers.

The sweep helper does not change OCI node-pool size. It labels the selected Ready workers, temporarily adds a matching selector to the Mooncake storage DaemonSet, waits for each owner rollout, invokes `benchmarks/scale-store.sh`, and deletes benchmark clients between points. Its exit trap restores the DaemonSet's exact saved selector, removes temporary node labels and waits for the original owners to become Ready. Owner pods restart while the selector changes, so schedule this during a maintenance window and expect the RAM cache to be cleared.

To reproduce an individual point manually, first arrange for exactly that many Mooncake owners to be Ready, then run (example for two owners):

```bash
OWNERS=2 CLIENTS_PER_OWNER=2 PROTOCOL=rdma DEVICE_NAME=mlx5_2 \
IMAGE="$STORE_IMAGE" bash benchmarks/scale-store.sh
kubectl -n mooncake delete pods -l app=mooncake-benchmark-client
```

The per-client logs, summaries, and generated pod manifests from the original run were saved on the bastion in:

```text
/home/opc/mooncake-oke-repro/mooncake-results-20261110T130743Z-owners-1
/home/opc/mooncake-oke-repro/mooncake-results-20261110T130743Z-owners-2
/home/opc/mooncake-oke-repro/mooncake-results-20261110T130743Z-owners-3
```

## Reproduce the full curve

The four-owner result was measured before the later 1/2/3 sweep, so the points were collected in separate runs. For a tighter comparison, rerun all four points in one session when four eligible Ready RDMA workers are available:

```bash
IMAGE="$STORE_IMAGE" \
OWNERS_SWEEP="1 2 3 4" \
CLIENTS_PER_OWNER=2 \
PROTOCOL=rdma \
DEVICE_NAME=mlx5_2 \
bash benchmarks/scale-store-same-pool.sh
```

The sweep helper temporarily changes only the Mooncake DaemonSet selector and restores it afterward; it does not resize the nodepool.
