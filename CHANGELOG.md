# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `invokeai-rocm/Dockerfile`: a thin AMD/ROCm derivative of the upstream
  InvokeAI image that reinstalls torch/torchvision/torchaudio/triton-rocm from
  PyTorch's self-contained ROCm 7.2 wheels. The upstream `main-rocm` tag ships
  ROCm 7.1, which SIGSEGVs (`exit 139`) on gfx1151 (Strix Halo / Radeon 8060S) at
  the first GPU operation (`ROCm/TheRock#2991`, `pytorch/pytorch#173367`); ROCm
  7.2 carries the fix.
- Agent integration examples under `openai-bridge/examples/`: the
  `generate-image.sh` helper, an opencode custom command plus an OpenAI-Images
  MCP fragment, and an oh-my-opencode-slim `image-generation` skill plus config
  example.
- `openai-bridge/README.md` "Using the bridge from an agent" section documenting
  the `/v1` contract, the helper script, and the opencode /
  oh-my-opencode-slim integration paths.
- Tracked bridge workflow/registry templates as plain JSON under
  `openai-bridge/templates/` (`workflows/sdxl-txt2img.json`, `registry.json`),
  baked into the image and seeded into `bridge-data` on first start instead of
  being hand-written into the volume.
- First-run startup discovery of the SDXL model reference: the entrypoint
  queries InvokeAI (`/api/v2/models/`, matching `base` + `type=main`) and
  patches the workflow with `jq`, bounded by the optional
  `BRIDGE_MODEL_WAIT_SECONDS`.
- `docker-compose.yml` defining `local-image-ai` with `invokeai-nvidia`
  (`nvidia` profile) and `invokeai-amd` (`amd` profile) sharing a common
  `x-invokeai-common` anchor, plus the always-on `openai-bridge`.
- `models-init` one-shot service that creates the ComfyUI-canonical model
  directory layout in the shared `ai-models` volume and chowns its top level.
- OpenAI-compatible `openai-bridge` built from upstream
  `openaiapi2invokeai-go` tag `v1.6`, with `PUID`/`PGID` privilege drop,
  first-run `registry.json` seeding, and full downstream proxy contract.
- `x-hosts` anchors deriving `invokeai.${BASE_DOMAIN}` and
  `images.${BASE_DOMAIN}`, with no host `ports:` and no `container_name:`.
- `env.example` documenting every global, invokeai and openai-bridge variable.
- `openai-bridge/Dockerfile`, `openai-bridge/docker/entrypoint.sh` and
  `openai-bridge/README.md`.
- Root `README.md`, `AGENTS.md` and this `CHANGELOG.md`; `.gitignore` ignoring
  `.env`.

### Changed

- `invokeai-amd` now sets gfx1151 / APU tuning
  (`TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1` + `..._CACHE=1`,
  `TORCH_BLAS_PREFER_HIPBLASLT=1`, `HSA_ENABLE_SDMA=0`,
  `MIOPEN_FIND_MODE=HYBRID`, and `MIOPEN_USER_DB_PATH` /
  `MIOPEN_CUSTOM_CACHE_DIR` under `/invokeai` — created by `invokeai-init` — so
  the MIOpen kernel database persists in the `invokeai-root` volume). Without
  AOTriton, ROCm SDPA falls back to the very slow math attention path, and
  consumer gfx1151 has no prebuilt MIOpen kernel DB, so without the persistent
  path every start recompiles conv kernels from source.
- `invokeai-amd` is now built locally (`build: ./invokeai-rocm` and
  `image: local-image-ai/invokeai-rocm:${INVOKEAI_ROCM_VERSION}`) instead of
  pulling the upstream `main-rocm` image directly.
- `env.example` / `.env` replace `INVOKEAI_IMAGE_ROCM` with
  `INVOKEAI_ROCM_VERSION` (required; currently `7.2.4`).
- The `openai-bridge` workflow templates switched from build-time `envsubst`
  substitution (via model-reference build args) to startup discovery: plain JSON
  templates are baked into the image and the model reference is resolved from
  InvokeAI during first-run seeding only. No build args or model values in
  `.env` are needed, and the runtime image now ships `jq`.
- The `openai-bridge` entrypoint now seeds `workflows/*` (not just
  `registry.json`) on first start and chowns the data dir recursively; the data
  dir is small config, so the chown is cheap and seeded files stay writable by
  the dropped user.
- Set `COMPOSE_PROFILES=nvidia` in `.env` / `env.example`, making the NVIDIA
  GPU profile the default for `docker compose up`; the AMD path is selected
  with `COMPOSE_PROFILES=amd docker compose up`.
- Moved InvokeAI's model store to a dedicated `invokeai-models` volume
  (`INVOKEAI_MODELS_DIR=/models`) outside `INVOKEAI_ROOT`; `ai-models` is now
  reserved as ComfyUI's own canonical store.
- The NVIDIA InvokeAI service now uses `runtime: nvidia` with
  `NVIDIA_VISIBLE_DEVICES=all` instead of a `deploy` device reservation. The
  device-request path left CUDA unable to initialize (`CUDA unknown error`) on
  an RTX 5090 + nvidia-open driver 615 host; the explicit runtime path works.

### Deprecated

### Removed

- Removed `INVOKEAI_IMAGE_ROCM`; the AMD base image is now hardcoded in
  `invokeai-rocm/Dockerfile` (the same convention the other Dockerfiles use).

### Fixed

- Fixed InvokeAI failing to start with `PermissionError: [Errno 13] Permission
  denied: '/models/model_images'`: the upstream entrypoint only chowns
  `INVOKEAI_ROOT` before dropping privileges, so the `invokeai-models` volume
  stayed root-owned. A new one-shot `invokeai-init` service now chowns its top
  level to `PUID`/`PGID` (and creates the persistent MIOpen cache directory)
  before the InvokeAI services start, and the variants pass
  `CONTAINER_UID=${PUID:-1000}` so the runtime user matches.
- Corrected the `README.md` agent example to request `response_format: b64_json`
  and decode `data[0].b64_json` (the bridge does not support image URLs).

### Security
