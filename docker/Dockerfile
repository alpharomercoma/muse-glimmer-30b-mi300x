# vLLM 0.28.0 on ROCm for AMD Instinct MI300X (gfx942).
#
# AMD's prebuilt rocm/vllm images lag upstream (newest ships vLLM 0.23.0), and
# Muse-Glimmer needs 0.28.0 for its muse_glimmer tool/reasoning parsers. The
# only published vLLM ROCm wheel is cp312 + ROCm 7.2.3, so this image is built
# on a Python 3.12 / ROCm 7.2.3 base to match it exactly.
FROM rocm/dev-ubuntu-24.04:7.2.3

ENV DEBIAN_FRONTEND=noninteractive

# The torch ROCm wheel dynamically links against OpenMPI and the full ROCm math
# library set. Neither ships in the -dev base image, and without them torch
# fails at import with:
#   OSError: libmpi_cxx.so.40: cannot open shared object file
#   ImportError: libMIOpen.so.1: cannot open shared object file
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv curl ca-certificates git \
      libopenmpi3t64 openmpi-bin libdw1 \
 && apt-get install -y --no-install-recommends rocm-libs miopen-hip rccl \
 && rm -rf /var/lib/apt/lists/*

# uv is used rather than pip because pip silently falls back to the CUDA wheels
# when the ROCm index has no match for the interpreter, which then fails at
# runtime on AMD hardware.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH=/root/.local/bin:/opt/venv/bin:$PATH
ENV VIRTUAL_ENV=/opt/venv
RUN uv venv /opt/venv --python 3.12
RUN uv pip install vllm --extra-index-url https://wheels.vllm.ai/rocm/

# Fail the build if we accidentally got a CUDA build instead of ROCm.
RUN python -c "import torch, vllm; assert torch.version.hip, 'not a ROCm torch build'; print('vllm', vllm.__version__, '| torch', torch.__version__)"

EXPOSE 8000
ENTRYPOINT ["vllm"]
