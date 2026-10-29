"""Fail image build/startup if the expected native CPU integration is absent."""
import importlib.metadata
import inspect
import torch
import vllm

assert vllm.__version__ == "0.32.0", vllm.__version__
assert torch.version.cuda is None, "This image must contain CPU-only Torch"
# The V2 CPU worker imports this module before constructing the model runner.
import vllm.v1.worker.cpu.shm  # noqa: E402
assert "Placeholder" in torch.cuda.Event.__name__, torch.cuda.Event
event = torch.cuda.Event()
event.record()
event.synchronize()
from mooncake.store import MooncakeDistributedStore, ReplicateConfig  # noqa: E402
from vllm.distributed.mooncake_store import MooncakeStoreConfig  # noqa: E402

MooncakeStoreConfig(
    mode="standalone-store", metadata_server="http://unused/metadata",
    master_server_address="unused:50051", protocol="tcp", device_name="",
    global_segment_size=0, local_buffer_size=268435456,
)
assert hasattr(MooncakeDistributedStore, "batch_get_into_multi_buffers")
assert hasattr(MooncakeDistributedStore, "batch_put_from_multi_buffers")
assert hasattr(ReplicateConfig(), "preferred_segment")
print("CPU integration preflight passed:", vllm.__version__,
      importlib.metadata.version("mooncake-transfer-engine"),
      "CPU event:", torch.cuda.Event.__name__,
      "native Store:", inspect.getfile(MooncakeDistributedStore))
