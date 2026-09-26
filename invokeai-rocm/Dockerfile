# syntax=docker/dockerfile:1
#
# invokeai-rocm — thin AMD/ROCm derivative of the upstream InvokeAI image.
#
# The upstream `main-rocm` tag (InvokeAI 6.14.1) ships the ROCm 7.1 torch stack.
# ROCm 7.1 computes an incorrect VGPR count for gfx1151 (Strix Halo / Radeon
# 8060S), so HSA queue setup corrupts memory and the process SIGSEGVs (exit 139)
# on the first GPU operation, even though `torch.cuda.is_available()` is True and
# `gfx1151` is in `torch.cuda.get_arch_list()`. The fix landed in ROCm 7.2
# (ROCm/TheRock#2991, pytorch/pytorch#173367, ROCm/ROCm#5853).
#
# This image keeps every InvokeAI layer and only swaps the torch stack to the
# ROCm 7.2 wheels from the same `download.pytorch.org` index the upstream image
# already uses (self-contained `manylinux` wheels; no system ROCm required).
# ROCm 7.2 has no torch 2.10.0 build, so torch moves to the 2.11.0 line and
# torchvision/torchaudio/triton-rocm follow.
#
# Remove this image once the upstream `main-rocm` tag ships ROCm >= 7.2
# (InvokeAI issue #9130). See README.md "AMD / ROCm (ROCm 7.2 derivative)".

FROM ghcr.io/invoke-ai/invokeai:main-rocm

# Documents the image this was built FROM (hardcoded, build-time only).
ENV BASE_IMAGE=ghcr.io/invoke-ai/invokeai:main-rocm

# Build timestamp recorded in the image (passed via compose build.args).
ARG BUILD_DATE=unknown
ENV BUILD_DATE=${BUILD_DATE}

# Matching release line for ROCm 7.2 (same source the upstream image uses).
ARG TORCH_VERSION=2.11.0
ARG TORCHVISION_VERSION=0.26.0
ARG TORCHAUDIO_VERSION=2.11.0
ARG TRITON_VERSION=3.7.1

# InvokeAI's venv is uv-managed and ships no pip. `--index-url` points at the
# ROCm 7.2 wheel index and `--no-deps` leaves the rest of the pinned image alone.
RUN uv pip install --python /opt/venv/bin/python --no-cache \
        --index-url "https://download.pytorch.org/whl/rocm7.2" \
        --no-deps --reinstall \
        "torch==${TORCH_VERSION}" \
        "torchvision==${TORCHVISION_VERSION}" \
        "torchaudio==${TORCHAUDIO_VERSION}" \
        "triton-rocm==${TRITON_VERSION}"

# Fail the build if the swap did not take. The compiled arch list can only be
# read with a GPU present (`get_arch_list()` is empty without a device), so
# `gfx1151` is checked at runtime instead.
RUN /opt/venv/bin/python -c \
    "import torch; assert torch.version.hip and torch.version.hip.startswith('7.2'), torch.version.hip; print('torch', torch.__version__, 'hip', torch.version.hip)"
