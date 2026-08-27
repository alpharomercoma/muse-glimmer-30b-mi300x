#!/usr/bin/env bash
# Step 3. Build the vLLM 0.28.0 ROCm image.
#
# Why build instead of pulling: AMD's prebuilt rocm/vllm images lag upstream.
# The newest published tag ships vLLM 0.23.0, which has no muse_glimmer parsers
# and cannot load MuseGlimmerForConditionalGeneration at all.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root."; exit 1; }
SRC="$(cd "$(dirname "$0")/.." && pwd)"
TAG=${TAG:-vllm-rocm:0.28.0-gfx942}

if docker image inspect "$TAG" > /dev/null 2>&1 && [ "${FORCE:-0}" != 1 ]; then
  echo "Image $TAG already exists. Set FORCE=1 to rebuild."
else
  echo "== Building $TAG (10-25 min: pulls ROCm libs and the torch wheel) =="
  docker build -t "$TAG" -f "$SRC/docker/Dockerfile" "$SRC/docker/"
fi

echo "== Verifying the image sees the GPU =="
RENDER_GID=$(getent group render | cut -d: -f3)
VIDEO_GID=$(getent group video | cut -d: -f3)
docker run --rm --entrypoint python \
  --device /dev/kfd --device /dev/dri \
  --group-add "$VIDEO_GID" --group-add "$RENDER_GID" \
  --security-opt seccomp=unconfined "$TAG" -c "
import torch, vllm, sys
if torch.cuda.device_count() == 0: sys.exit('FAIL: no GPU inside container')
p = torch.cuda.get_device_properties(0)
print(f'  vllm {vllm.__version__} | torch {torch.__version__}')
print(f'  {p.name} | {p.gcnArchName} | {p.total_memory/1024**3:.1f} GiB')
from vllm.model_executor.models.registry import ModelRegistry
a = ModelRegistry.get_supported_archs()
assert 'MuseGlimmerForConditionalGeneration' in a, 'FAIL: MuseGlimmer not supported'
print('  MuseGlimmerForConditionalGeneration: supported')
"
