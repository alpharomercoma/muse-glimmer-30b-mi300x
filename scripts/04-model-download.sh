#!/usr/bin/env bash
# Step 4. Download Muse-Glimmer-30B (about 56 GB). Resumable.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root."; exit 1; }
MODEL_REPO=${MODEL_REPO:-meta-models/Muse-Glimmer-30B}
MODEL_DIR=${MODEL_DIR:-/models/Muse-Glimmer-30B}
VENV=/opt/hfenv

if [ ! -x "$VENV/bin/hf" ]; then
  echo "== Installing Hugging Face CLI =="
  # "python3 -m venv" fails with "ensurepip is not available" unless the
  # version-matched venv package is present; the name tracks the python version.
  PYVER=$(python3 -c 'import sys;print(f"{sys.version_info.major}.{sys.version_info.minor}")')
  apt-get install -y "python${PYVER}-venv" 2>/dev/null || apt-get install -y python3-venv
  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install --upgrade pip
  # huggingface_hub 1.x has no [cli] or [hf_transfer] extras; it uses the Xet
  # backend for parallel transfer by default.
  "$VENV/bin/pip" -q install "huggingface_hub>=1.0"
fi

mkdir -p "$(dirname "$MODEL_DIR")"
echo "== Downloading $MODEL_REPO -> $MODEL_DIR (about 56 GB) =="
"$VENV/bin/hf" download "$MODEL_REPO" --local-dir "$MODEL_DIR" --max-workers 16

echo "== Verifying =="
shards=$(ls "$MODEL_DIR"/*.safetensors 2>/dev/null | wc -l)
expected=$(python3 -c "
import json
idx='$MODEL_DIR/model.safetensors.index.json'
print(len({v for v in json.load(open(idx))['weight_map'].values()}))" 2>/dev/null || echo 0)
for f in config.json tokenizer.json chat_template.jinja generation_config.json; do
  [ -f "$MODEL_DIR/$f" ] || { echo "MISSING $f"; exit 1; }
done
echo "  shards: $shards (index expects $expected)"
[ "$shards" = "$expected" ] || { echo "Shard count mismatch. Re-run to resume."; exit 1; }
echo "  size:   $(du -sh "$MODEL_DIR" | cut -f1)"
echo "Model ready."
