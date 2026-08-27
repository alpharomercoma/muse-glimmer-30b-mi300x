#!/usr/bin/env bash
# Benchmark the running server.
# usage: bench.sh [input_len] [output_len] [num_prompts] [concurrency]
set -uo pipefail
source /opt/muse/env
KEY=$( [ -r /etc/vllm/api-key ] && cat /etc/vllm/api-key || echo "dummy" )
docker run --rm --network host --entrypoint vllm \
  -v "${MODEL_DIR}":"${MODEL_DIR}":ro \
  -e HF_HUB_OFFLINE=1 -e OPENAI_API_KEY="$KEY" "$IMAGE" \
  bench serve \
    --backend openai-chat --endpoint /v1/chat/completions \
    --base-url "http://127.0.0.1:${PORT}" \
    --model "$SERVED_NAME" --tokenizer "$MODEL_DIR" \
    --dataset-name random --random-input-len "${1:-2048}" --random-output-len "${2:-256}" \
    --num-prompts "${3:-64}" --max-concurrency "${4:-16}" \
    --percentile-metrics ttft,tpot,itl,e2el
