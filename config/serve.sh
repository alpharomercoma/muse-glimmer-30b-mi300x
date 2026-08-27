#!/usr/bin/env bash
# Launch vLLM 0.28.0 serving Muse-Glimmer-30B on one AMD MI300X.
set -euo pipefail
source /opt/muse/env

# Defaults so an older env file missing a newer knob does not abort under set -u.
: "${BIND_ADDR:=127.0.0.1}"
: "${PORT:=8000}"
: "${TP:=1}"
: "${MAX_MODEL_LEN:=131072}"
: "${GPU_MEM_UTIL:=0.50}"
: "${MAX_NUM_SEQS:=64}"
: "${MAX_NUM_BATCHED_TOKENS:=8192}"
: "${LIMIT_MM_IMAGE:=4}"
: "${USE_AITER:=1}"
: "${USE_ASYNC_SCHED:=1}"
: "${USE_PREFIX_CACHE:=1}"

# The container image has no "render"/"video" group by name, so
# "--group-add render" fails with "unable to find group render".
# Numeric host GIDs must be used instead.
RENDER_GID=$(getent group render | cut -d: -f3)
VIDEO_GID=$(getent group video | cut -d: -f3)

ARGS=(
  serve "$MODEL_DIR"
  --served-model-name "$SERVED_NAME"
  --host 0.0.0.0 --port 8000
  --tensor-parallel-size "$TP"
  --max-model-len "$MAX_MODEL_LEN"
  --gpu-memory-utilization "$GPU_MEM_UTIL"
  --max-num-seqs "$MAX_NUM_SEQS"
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS"
  --limit-mm-per-prompt "{\"image\":${LIMIT_MM_IMAGE}}"
  # Muse-Glimmer uses the ATEM protocol (<atem:invoke ...>, <|start|>/<|message|>
  # channel tokens), NOT Hermes JSON or Qwen XML. vLLM 0.28.0 ships dedicated
  # muse_glimmer parsers; any other parser returns 200 with plausible text but
  # never emits tool_calls, so agents silently fail to use tools.
  --enable-auto-tool-choice
  --tool-call-parser muse_glimmer
  --reasoning-parser muse_glimmer
)
[ "$USE_PREFIX_CACHE" = 1 ] && ARGS+=(--enable-prefix-caching)
[ "$USE_ASYNC_SCHED"  = 1 ] && ARGS+=(--async-scheduling)

ENVS=(
  -e VLLM_ROCM_USE_AITER="$USE_AITER"
  -e TORCH_BLAS_PREFER_HIPBLASLT=1
  -e SAFETENSORS_FAST_GPU=1
  -e HF_HUB_OFFLINE=1
  -e VLLM_NO_USAGE_STATS=1
)
# Defence in depth. The Caddy proxy is the real gate.
[ -r /etc/vllm/api-key ] && ENVS+=(-e VLLM_API_KEY="$(cat /etc/vllm/api-key)")

exec docker run --rm --name muse-glimmer \
  --device /dev/kfd --device /dev/dri \
  --group-add "$VIDEO_GID" --group-add "$RENDER_GID" \
  --ipc=host --shm-size 32g \
  --security-opt seccomp=unconfined --cap-add SYS_PTRACE \
  -p "${BIND_ADDR}:${PORT}:8000" \
  -v "${MODEL_DIR}":"${MODEL_DIR}":ro \
  -v /root/.cache/vllm:/root/.cache/vllm \
  "${ENVS[@]}" "$IMAGE" "${ARGS[@]}"
