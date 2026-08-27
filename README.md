# Muse-Glimmer-30B on AMD MI300X with vLLM 0.28.0

Reproducible setup for serving `meta-models/Muse-Glimmer-30B` on a single AMD
Instinct MI300X, exposed as an OpenAI compatible HTTPS endpoint with API key
auth, and driven from the `pi` CLI on a local machine.

Everything used here is free and open source.

## Why this repo builds its own vLLM image

AMD's prebuilt `rocm/vllm` images lag upstream. The newest published tag ships
vLLM **0.23.0**, which does not know `MuseGlimmerForConditionalGeneration` and
has no `muse_glimmer` parsers, so it cannot load this model at all.

vLLM publishes exactly one ROCm wheel, `vllm-0.28.0+rocm723-cp312`, which is
**Python 3.12 and ROCm 7.2.3 only**. This repo therefore builds a small image on
a matching Python 3.12 / ROCm 7.2.3 base. The result is 11 GB, versus 68.9 GB
for AMD's image.

## Verified environment

Built and tested end to end on:

| Component | Version |
|---|---|
| OS | Ubuntu 26.04 LTS |
| Kernel | 7.0.0-27-generic |
| GPU | AMD Instinct MI300X VF, gfx942, 191.7 GiB |
| Docker | 29.7.2 |
| Base image | `rocm/dev-ubuntu-24.04:7.2.3` |
| Built image | `vllm-rocm:0.28.0-gfx942` (11 GB) |
| vLLM | 0.28.0+rocm723 |
| torch | 2.12.0+git6bbd260 (ROCm) |
| transformers | 5.16.1 |
| Caddy | 2.11.4 |
| pi | 0.84.3 |

Disk needed: about 130 GB (11 GB image, 56 GB weights, plus build cache).

## What the model is

`MuseGlimmerForConditionalGeneration`, `model_type: muse_glimmer`, Apache 2.0.

* Dense, 52 layers, hidden 6656, 32 attention heads, 2 KV heads (GQA).
* **Hybrid sliding attention**: 39 sliding_attention plus 13 full_attention
  layers. This makes KV cache very cheap. 37.47 GiB of cache holds
  **2,125,299 tokens**.
* **Multimodal**, accepts images.
* 131072 token context, vocab 202048.
* Tool calls use the **ATEM protocol**: `<atem:invoke name="...">` inside
  `<atem:function_calls>`, with `<|start|>` / `<|message|>` / `<|eot|>` channel
  tokens and a separate reasoning channel. This is **not** Hermes JSON and not
  Qwen XML. The parser must be `muse_glimmer` for both tools and reasoning.

## Quick start

```bash
git clone git@github.com:alpharomercoma/muse-glimmer-30b-mi300x.git
cd muse-glimmer-30b-mi300x

sudo ./scripts/00-preflight.sh          # check the machine
sudo ./scripts/01-gpu-firmware.sh       # only if preflight fails on the GPU, then reboot
sudo ./scripts/02-docker.sh             # install docker
sudo ./scripts/03-build-image.sh        # build vLLM 0.28.0 ROCm image
sudo ./scripts/04-model-download.sh     # download weights, about 56 GB
sudo ./scripts/05-serve-install.sh      # install service and start
./scripts/smoke.sh                      # verify

# optional, for access from other machines
sudo ACME_EMAIL=you@example.com ./scripts/06-endpoint-secure.sh
./scripts/client-config.sh              # prints local machine setup
```

## Step by step

### Step 0. Preflight

```bash
sudo ./scripts/00-preflight.sh
```

Checks the MI300X on the PCI bus, the `amdgpu` module, a real KFD node, the
amdgpu firmware blobs, disk, and RAM. Changes nothing.

The KFD check is the one that matters. `/dev/kfd` can exist while the GPU failed
to initialise, in which case the topology node reports `simd_count 0` and every
ROCm tool claims there is no GPU.

### Step 1. GPU firmware

Only if preflight fails on the GPU or firmware checks.

```bash
sudo ./scripts/01-gpu-firmware.sh
sudo reboot
```

Re-run preflight after rebooting. It must pass before continuing.

### Step 2. Docker

```bash
sudo ./scripts/02-docker.sh
```

ROCm userspace is not needed on the host. The container ships its own ROCm and
talks to the host `amdgpu` kernel driver through `/dev/kfd` and `/dev/dri`.

### Step 3. Build the image

```bash
sudo ./scripts/03-build-image.sh
```

Takes 10 to 25 minutes. The Dockerfile ends with an assertion that the installed
torch is a ROCm build, so a silent CUDA fallback fails the build rather than
failing later at runtime. The script then confirms the image sees the GPU and
that `MuseGlimmerForConditionalGeneration` is in the registry.

Set `FORCE=1` to rebuild an existing image.

### Step 4. Download the model

```bash
sudo ./scripts/04-model-download.sh
```

About 56 GB into `/models/Muse-Glimmer-30B`. Resumable. Verifies the shard count
against `model.safetensors.index.json`. Apache 2.0 and not gated, so no
`HF_TOKEN` is required.

### Step 5. Install and start

```bash
sudo ./scripts/05-serve-install.sh
```

Installs `/opt/muse/env`, `/opt/muse/serve.sh` and the `muse-glimmer` systemd
unit, then starts and waits. First start takes 5 to 15 minutes for weight
loading, AITER JIT and `torch.compile`. Later starts reuse the cache in
`/root/.cache/vllm`.

```bash
systemctl status muse-glimmer
journalctl -u muse-glimmer -f
```

### Step 6. Verify

```bash
./scripts/smoke.sh                       # local
./scripts/smoke.sh https://your-domain   # through the proxy
```

Checks health, model list, chat, **tool calling**, and streaming. Expected output
ends with `SMOKE PASS`.

The tool call check matters most. A wrong parser still returns 200 with plausible
text but never emits `tool_calls`, so agents silently fail to use tools.

### Step 7. Expose it, optional

```bash
sudo ACME_EMAIL=you@example.com ./scripts/06-endpoint-secure.sh
```

```
client --HTTPS + Bearer key--> Caddy :443 --http--> vLLM 127.0.0.1:8000
```

Generates an API key at `/etc/vllm/api-key`, installs Caddy, obtains a Let's
Encrypt certificate, enables `ufw` with SSH allowed first, and restarts the
server bound to loopback.

The default certificate hostname is `<public-ip>.nip.io`, a free DNS service
that resolves the name back to the IP, so no domain purchase is needed. For your
own domain, point an A record at the machine and pass `VLLM_DOMAIN=...`.

### Step 8. Local machine

```bash
./scripts/client-config.sh
```

Prints the endpoint, key, and exact files to create. Summary:

1. `npm install -g --ignore-scripts @earendil-works/pi-coding-agent` (Node 20+)
2. Copy `client/models.json` to `~/.pi/agent/models.json`, replacing the domain.
3. Copy `client/settings.json` to `~/.pi/agent/settings.json`.
4. `export MI300X_API_KEY='sk-mi300x-...'` in your shell profile.
5. Run `pi`. With settings in place, bare `pi` needs no flags.

Inside a session, `/model` switches models, `/thinking` sets reasoning depth,
`/settings` opens the config menu, and `Ctrl+S` saves a default.

For scripts, redirect stdin: `pi -p "prompt" < /dev/null`. Do not do this
interactively, since it closes the input you type into.

## Tuning

Knobs live in `/opt/muse/env`. Change one, then `systemctl restart muse-glimmer`.

| Variable | Default | Meaning |
|---|---|---|
| `BIND_ADDR` | `127.0.0.1` | Publish address. Keep loopback. See Security. |
| `MAX_MODEL_LEN` | `131072` | Context length |
| `TP` | `1` | Tensor parallel size |
| `GPU_MEM_UTIL` | `0.50` | Fraction of VRAM vLLM may claim. See note below. |
| `MAX_NUM_SEQS` | `64` | Max concurrent sequences |
| `MAX_NUM_BATCHED_TOKENS` | `8192` | Prefill batch budget |
| `LIMIT_MM_IMAGE` | `4` | Max images per prompt |
| `USE_AITER` | `1` | AMD AITER fused kernels |
| `USE_ASYNC_SCHED` | `1` | Overlap scheduling with GPU execution |
| `USE_PREFIX_CACHE` | `1` | Reuse the system prompt across turns |

`GPU_MEM_UTIL` is set to 0.50 because this machine also runs a separate Mistral
server holding about 84 GiB. **Raise it to 0.90 if the GPU is dedicated to
Muse-Glimmer alone.** See the sharing note below for why the value is not simply
a fraction of the whole card.

### Measured performance

`vllm bench serve`, random dataset, 2048 input and 256 output tokens, measured
**while sharing the GPU with the Mistral server** at `GPU_MEM_UTIL=0.50`. A
dedicated GPU would do better.

| Concurrency | Output tok/s | Total tok/s | TTFT | TPOT |
|---|---|---|---|---|
| 1 | 46.4 | 427 | 250 ms | 20.7 ms |
| 16 | 412.2 | 3798 | 1883 ms | 31.5 ms |

Weights load at 55.57 GiB, leaving 37.47 GiB of KV cache, which holds
**2,125,299 tokens** thanks to the sliding attention layout.

There is no MTP head in this model, so no self speculative decoding. vLLM 0.28.0
does register `MuseGlimmerAssistantModel` and `DFlashMuseGlimmerAssistantModel`,
which are separate draft models. Pairing one of those would mainly help single
stream latency, and is untested here.

```bash
/opt/muse/bench.sh 2048 256 64 16     # input, output, prompts, concurrency
```

## Sharing the GPU with another model

vLLM compares `GPU_MEM_UTIL x TOTAL VRAM` against **free** VRAM at startup, not
against total. With another server already holding 84 GiB of a 191.7 GiB card,
any value above about 0.55 fails immediately with:

```
ValueError: Free memory on device cuda:0 (107.21/191.69 GiB) on startup is less
than desired GPU memory utilization (0.92, 176.35 GiB).
```

So when co-tenanting, set `GPU_MEM_UTIL` to a fraction of the **whole card** that
still fits inside what is free. Two servers at 0.50 and 0.44 coexist; 0.92 and
0.44 do not.

## Security

1. **vLLM binds to `127.0.0.1`.** Docker's iptables rules bypass `ufw`, so a
   firewall rule alone does not close a published container port. Binding to
   loopback is the control that actually closes it.
   Check: `ss -tlnp | grep 8000` should show `127.0.0.1:8000`.
2. **Auth is enforced at the proxy, on every path.** vLLM's own `--api-key` only
   protects `/v1`, `/v2` and `/inference`, and leaves `/invocations`
   unauthenticated even though it exposes the same inference capability. Caddy
   rejects any request without the exact bearer token on all paths.
   Check: `curl -o /dev/null -w '%{http_code}' -X POST https://YOUR_DOMAIN/invocations -d '{}'`
   should return 401.
3. **Caddy's stock systemd unit leaks the API key.** It runs
   `caddy run --environ`, printing every environment variable, including
   `VLLM_API_KEY`, into the journal on each start. The override in
   `config/caddy-override.conf` removes that flag. Do not re-add it.

Rotate the key:

```bash
printf 'sk-mi300x-%s' "$(openssl rand -hex 24)" | sudo tee /etc/vllm/api-key > /dev/null
sudo sed -i "s|^VLLM_API_KEY=.*|VLLM_API_KEY=$(sudo cat /etc/vllm/api-key)|" /etc/caddy/vllm.env
sudo systemctl restart caddy muse-glimmer
```

There is no rate limiting. Caddy's `rate_limit` module needs a custom build. The
API key is the only gate, so treat it as a password.

## Errors you may hit

All of these were encountered during this build.

### `rocm/vllm` has no image new enough

The newest published tag ships vLLM 0.23.0. Muse-Glimmer needs 0.28.0. There is
no ROCm image with it, and `rocm/vllm-dev` publishes only CI base images with no
vLLM installed. Build the image in step 3 instead of hunting for a tag.

### pip silently installs the CUDA build

The ROCm wheel index has exactly one vLLM wheel, `cp312` for ROCm 7.2.3. On any
other Python version pip falls back to the **CUDA** wheels from PyPI without
error, and the failure only appears later at runtime on AMD hardware. This repo
uses `uv` on a Python 3.12 base for that reason, and the Dockerfile asserts
`torch.version.hip` is set so a fallback fails the build.

### `OSError: libmpi_cxx.so.40: cannot open shared object file`

The torch ROCm wheel links against OpenMPI, which is not in the ROCm dev base
image. Fix: `apt-get install libopenmpi3t64 openmpi-bin`. Already in the
Dockerfile.

### `ImportError: libMIOpen.so.1: cannot open shared object file`

The dev base image also lacks the ROCm math libraries. Twelve are missing in
total: `libMIOpen`, `libhipblas`, `libhipblaslt`, `libhipfft`, `libhiprand`,
`libhipsolver`, `libhipsparse`, `libhipsparselt`, `librccl`, `librocblas`,
`librocsolver`, and `libdw`. Fix: `apt-get install rocm-libs miopen-hip rccl
libdw1`. Already in the Dockerfile.

To find them all at once rather than one at a time:

```bash
for f in .../site-packages/torch/lib/*.so*; do ldd "$f" 2>/dev/null | grep "not found"; done \
  | awk '{print $1}' | sort -u
```

### `Free memory on device cuda:0 ... is less than desired GPU memory utilization`

Another process holds VRAM. `GPU_MEM_UTIL` is measured against total VRAM but
checked against free VRAM. See the sharing section above.

### Tool calls never appear

Symptom: chat works, `tool_calls` is always null, and ATEM markup leaks into the
message content.

Cause: wrong parser. Muse-Glimmer uses the ATEM protocol, not Hermes or Qwen XML.

Fix: `--tool-call-parser muse_glimmer --reasoning-parser muse_glimmer`.
`./scripts/smoke.sh` fails loudly on this.

### Empty completion content

`content` is empty and `finish_reason` is `length`. The model writes a reasoning
channel first, and a small `max_tokens` is consumed entirely by it. Use 512 or
more.

### A healthy service looks dead to `systemctl is-active --quiet`

`systemctl is-active` exits non-zero for `activating` and `deactivating`, not
only `failed`, so a naive wait loop aborts on a service that is still starting.
Check for terminal states explicitly:

```bash
state=$(systemctl is-active muse-glimmer || true)
case "$state" in failed|inactive) exit 1 ;; esac
```

`ExecStop` is `docker stop -t 60`, so a restart can sit in `deactivating` for up
to a minute. That is normal.

### GPU reports as absent, `/dev/kfd` exists but is a stub

```
amdgpu: Direct firmware load for amdgpu/gc_9_4_3_rlc.bin failed with error -2
amdgpu: Fatal error during GPU init
amdgpu: no gpu node! Cannot create KFD process
```

`linux-firmware-amd-graphics` is missing. Run `01-gpu-firmware.sh` and reboot.
Do **not** try `modprobe -r amdgpu` to avoid the reboot; on a failed-init device
the unload crashes and wedges the module in state `going` until a reboot.

## Layout

```
docker/Dockerfile          vLLM 0.28.0 on ROCm 7.2.3, Python 3.12
scripts/
  00-preflight.sh          check the machine, changes nothing
  01-gpu-firmware.sh       install amdgpu firmware, needs reboot
  02-docker.sh             install docker
  03-build-image.sh        build and verify the vLLM image
  04-model-download.sh     download and verify weights
  05-serve-install.sh      install service and start
  06-endpoint-secure.sh    api key, caddy, tls, firewall
  smoke.sh                 health, chat, tool calling, streaming
  bench.sh                 throughput and latency
  client-config.sh         print client setup
config/
  muse.env                 tunables, installed to /opt/muse/env
  serve.sh                 docker run wrapper
  muse-glimmer.service     systemd unit
  Caddyfile                reverse proxy with auth on every path
  caddy-override.conf      systemd override that removes --environ
client/
  models.json              pi provider template
  settings.json            pi defaults template
```

Files created on the server:

```
/opt/muse/env              tunables
/opt/muse/serve.sh         launcher
/opt/hfenv/                venv for the HF downloader
/models/Muse-Glimmer-30B/  weights
/etc/vllm/api-key          API key, mode 600
/etc/caddy/Caddyfile       proxy config
/etc/caddy/vllm.env        proxy secrets, mode 640 root:caddy
/root/.cache/vllm/         torch.compile cache
```

## Related

`git@github.com:alpharomercoma/qwen3.8-27b-mi300x.git` is the same stack for
Qwen3.8-27B on AMD's prebuilt vLLM 0.23.0 image, for models that do not need a
newer vLLM.

## License

Scripts in this repository are MIT. Muse-Glimmer-30B is Apache 2.0. vLLM is
Apache 2.0. Caddy is Apache 2.0.
