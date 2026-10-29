# Reproducible CPU-only Mooncake Store image for x86_64 Ubuntu/OKE workers.
# Build dependencies and source are pinned; update the commit intentionally.
FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive
ARG MOONCAKE_COMMIT=f7baeb138db8f14bb158e9fc6c84d1a1bd6178f6
ARG BUILD_JOBS=2

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake git ca-certificates curl pkg-config ninja-build \
      libibverbs-dev librdmacm-dev libnuma-dev liburing-dev libssl-dev \
      libcurl4-openssl-dev libgoogle-glog-dev libgflags-dev libaio-dev \
      python3 python3-dev python3-pip python3-venv util-linux tini \
    && rm -rf /var/lib/apt/lists/*

RUN git init /opt/Mooncake \
    && git -C /opt/Mooncake remote add origin https://github.com/kvcache-ai/Mooncake.git \
    && git -C /opt/Mooncake fetch --depth 1 origin "${MOONCAKE_COMMIT}" \
    && git -C /opt/Mooncake checkout --detach FETCH_HEAD \
    && test "$(git -C /opt/Mooncake rev-parse HEAD)" = "${MOONCAKE_COMMIT}"
WORKDIR /opt/Mooncake
RUN bash dependencies.sh --yes
RUN cmake -S /opt/Mooncake -B /opt/Mooncake/build-store \
      -DCMAKE_BUILD_TYPE=Release \
      -DWITH_TE=ON -DWITH_STORE=ON -DWITH_STORE_RUST=OFF \
      -DUSE_CUDA=OFF -DUSE_VRAM_SEGMENT=OFF \
      -DUSE_ETCD=OFF -DSTORE_USE_ETCD=OFF -DSTORE_USE_REDIS=OFF \
      -DSTORE_USE_K8S_LEASE=OFF -DUSE_REDIS=OFF -DUSE_HTTP=ON -DUSE_TCP=ON \
      -DBUILD_UNIT_TESTS=OFF -DBUILD_BENCHMARK=OFF -DBUILD_EXAMPLES=OFF
RUN cmake --build /opt/Mooncake/build-store --parallel "${BUILD_JOBS}" \
      --target mooncake_master mooncake_client store

ENV PATH="/opt/Mooncake/build-store/mooncake-store/src:/usr/local/bin:${PATH}" \
    PYTHONPATH="/opt/Mooncake/build-store/mooncake-integration" \
    MOONCAKE_STORE_MODULE=_store \
    LD_LIBRARY_PATH="/opt/Mooncake/build-store/mooncake-common:/opt/Mooncake/build-store/mooncake-store/src:/opt/Mooncake/build-store/mooncake-transfer-engine/src:/opt/Mooncake/build-store/mooncake-store/src/local_ssd"
RUN mooncake_master --version && mooncake_client --version \
    && python3 -c 'import _store; print("Mooncake Store Python binding OK")'
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["mooncake_client", "--help"]
