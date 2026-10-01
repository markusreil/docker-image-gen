# image-ai

A local, self-hosted AI image-generation stack. It ships the **InvokeAI** and
**ComfyUI** WebUIs for interactive use and an **OpenAI-compatible bridge** so
agents and OpenAI-API clients can generate images. Both WebUIs run on the same
NVIDIA/AMD profile pattern and share the ComfyUI-canonical `ai-models` store.

## Architecture

```
  agents / OpenAI SDK                     you (browser)
        │                    ┌──────────────────┴──────────────────┐
        │ images.<domain>/v1 │ invokeai.<domain>   comfyui.<domain> │
        ▼                    ▼                                     ▼
  ┌────────────────────────── external reverse-proxy cluster ──────────────────────────┐
  │                    (owns all public endpoints; no host ports here)                  │
  └───────┬──────────────────────┬─────────────────────────┬───────────────────────────┘
          │ web-proxy            │ web-proxy               │ web-proxy
          ▼                      ▼                         ▼
   ┌───────────────┐   internal  ┌────────────────────┐   ┌────────────────────┐
   │ openai-bridge │ ──────────▶ │ invokeai nvidia|amd│   │ comfyui nvidia|amd │
   │    :8080      │   :9090     │        :9090       │   │        :8188       │
   └───────┬───────┘             └──────────┬─────────┘   └──────────┬─────────┘
           │ /data (bridge-data)            │ /invokeai             │ /comfyui/*
           │                                │ /models (invokeai-    │ /comfyui/models
           │                                │         models)       │         (ai-models)
           └────────────────────────────────┴───────────────────────┘
      ai-models (seeded by models-init) is the shared ComfyUI-canonical store.
      invokeai-models is InvokeAI's own flat <uuid>/ store and is NOT
      consumable by ComfyUI; share bytes by importing from ai-models into
      InvokeAI as external (absolute-path) models.
```

## Services

| Service | Profile | Image | Purpose |
| --- | --- | --- | --- |
| `models-init` | — (one-shot) | `alpine:3.22` | Creates the ComfyUI-canonical model layout in `ai-models`. |
| `invokeai-init` | — (one-shot) | `alpine:3.22` | Fixes `invokeai-models` ownership and creates the MIOpen cache dir before InvokeAI starts. |
| `comfyui-init` | — (one-shot) | `alpine:3.22` | Creates ComfyUI's persistent MIOpen cache dir. |
| `invokeai-nvidia` | `nvidia` | `${INVOKEAI_IMAGE_CUDA}` | InvokeAI WebUI + API on NVIDIA GPUs. |
| `invokeai-amd` | `amd` | built from `invokeai-rocm/Dockerfile` | InvokeAI WebUI + API on AMD GPUs (ROCm 7.2 derivative). |
| `comfyui-nvidia` | `nvidia` | `${COMFYUI_IMAGE_CUDA}` | ComfyUI WebUI on NVIDIA GPUs. |
| `comfyui-amd` | `amd` | `${COMFYUI_IMAGE_ROCM}` | ComfyUI WebUI on AMD GPUs (ROCm 7.2.3). |
| `openai-bridge` | — (always on) | built from `./openai-bridge` | OpenAI-compatible `/v1` bridge to InvokeAI. |

All state lives in named volumes: `invokeai-root`, `invokeai-models`,
`ai-models`, `comfyui-nodes`, `comfyui-user`, `comfyui-input`,
`comfyui-output`, `comfyui-cache`, `bridge-data`.

## Quickstart

```sh
cp env.example .env      # then edit .env
# ... set BASE_DOMAIN, BRIDGE_API_KEY, BRIDGE_ADMIN_USER/PASS, PUID/PGID ...

# `COMPOSE_PROFILES=nvidia` is set in .env, so the NVIDIA variant is the default:
docker compose up -d

# AMD (a shell env var overrides the .env value):
COMPOSE_PROFILES=amd docker compose up -d

docker compose ps
```

The **proxy cluster must already be running** (see below). Syncing is fine
because the proxy network is external. `docker compose up` is intentionally
not used during verification, since the `web-proxy` network belongs to a
separate proxy cluster that may not exist on every host.

## Prerequisites

- Docker Engine + Docker Compose v2.
- **NVIDIA**: NVIDIA driver and the [NVIDIA Container
  Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html),
  registered with Docker via
  `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`.
  The NVIDIA variant uses `runtime: nvidia` (see [Troubleshooting](#troubleshooting)).
- **AMD**: a ROCm-capable kernel driver (`amdgpu`), plus membership/access to
  the `video` and `render` groups on the host. The services pass `/dev/kfd`
  and `/dev/dri` through and set `shm_size: 8g`. InvokeAI's AMD image is built
  locally on first use (see [AMD / ROCm](#amd--rocm-rocm-72-derivative));
  ComfyUI's AMD image is pulled from GHCR.
- **ComfyUI**: pulled from a third-party image (there is no official one; see
  [ComfyUI](#comfyui)). The GPU layers are large, so the first pull is slow.
- A running reverse-proxy cluster that created the `web-proxy` network and
  serves `BASE_DOMAIN`.

## Reverse-proxy contract

No service publishes `ports:`. Each proxied service attaches to the external
`web-proxy` network (named by `NGINX_PROXY_NETWORK`, default `web-proxy`) and
declares its **complete** downstream contract:

- `VIRTUAL_HOST` / `VIRTUAL_PORT` — always.
- `ACME_HOST` — the publicly-trusted certificate opt-in (internet-facing).
- `GEN_SELF_SIGNED_CERT` — the self-signed opt-in (LAN/local testing),
  defaulting to `false` and overridable per service via
  `INVOKEAI_GEN_SELF_SIGNED_CERT` / `COMFYUI_GEN_SELF_SIGNED_CERT` /
  `BRIDGE_GEN_SELF_SIGNED_CERT`.

Because both opt-ins are declared, the same compose file works in either proxy
variant; the proxy honours only the one that matches. **Start the proxy cluster
first** — its network is consumed as `external: true` here.

Hostnames are defined once in `x-hosts`:

- InvokeAI → `invokeai.${BASE_DOMAIN}`
- ComfyUI → `comfyui.${BASE_DOMAIN}`
- Bridge → `images.${BASE_DOMAIN}`

## Model storage

There are two independent stores; `ai-models` is the shared canonical tree.

- **`ai-models`** — ComfyUI's canonical store, seeded by `models-init`
  (`checkpoints`, `loras`, `vae`, ...) and mounted at `/comfyui/models` in both
  ComfyUI variants. It is the **shared byte source**: download models here (or
  export them from InvokeAI) and add them to InvokeAI as **external** models by
  absolute path (InvokeAI "Add Model" → scan folder). Bulk-load with the
  one-off container below.
- **`invokeai-models`** — InvokeAI's managed store, mounted at `/models` with
  `INVOKEAI_MODELS_DIR=/models`. Since InvokeAI 6.9 it is a flat `<uuid>/`
  layout (`<uuid>/model.safetensors`) tracked in InvokeAI's database, so ComfyUI
  **cannot** consume it directly: there are no `checkpoints/`, `vae/`, ...
  type subdirectories to map in `extra_model_paths.yaml`, and the filenames are
  opaque. Do **not** mount it into ComfyUI. Conversely, never point InvokeAI's
  `models_dir` at the ComfyUI tree: InvokeAI rewrites its managed dir and
  `Sync Models` can recursively delete orphan folders.

`invokeai-init` chowns the top level of `invokeai-models` to `PUID`/`PGID`
(`invokeai-root` stays outside the store, so the upstream entrypoint's recursive
chown never walks it) and creates InvokeAI's persistent MIOpen cache directory;
`comfyui-init` creates ComfyUI's MIOpen cache directory. The InvokeAI images run
as `PUID` (`CONTAINER_UID=${PUID:-1000}` keeps them aligned); the ComfyUI images
run as root, so only InvokeAI's store needs the ownership fix.

Bulk-load ComfyUI-style models into `ai-models` with a one-off container:

```sh
docker run --rm -v image-ai_ai-models:/models -v "$PWD":/src alpine:3.22 \
  cp /src/my-model.safetensors /models/checkpoints/
```

(If the project directory is renamed, the volume prefix changes; check
`docker volume ls | grep ai-models`.)

## ComfyUI

ComfyUI runs as a `comfyui-nvidia` / `comfyui-amd` pair under the same
`nvidia` / `amd` profiles as InvokeAI, sharing one `x-comfyui-common` anchor,
the internal alias `comfyui`, and the hostname `comfyui.${BASE_DOMAIN}`.

ComfyUI has **no official image**, so both variants use the same maintained
community family
([`radiatingreverberations/comfyui-docker`](https://github.com/radiatingreverberations/comfyui-docker),
image `ghcr.io/radiatingreverberations/comfyui-extensions`):

- `--profile nvidia` → `COMFYUI_IMAGE_CUDA` (CUDA 13.0.3).
- `--profile amd` → `COMFYUI_IMAGE_ROCM` (ROCm 7.2.3 + PyTorch 2.11.0 — the
  same ROCm line as the InvokeAI AMD derivative, required on gfx1151 / Strix
  Halo).

The image runs as root and already serves `0.0.0.0:8188`; the service exposes
that port and adds the full proxy contract. Persistent named volumes:
`ai-models` (`/comfyui/models`), `comfyui-nodes` (`custom_nodes`),
`comfyui-user`, `comfyui-input`, `comfyui-output`, and `comfyui-cache`
(`/root/.cache`, holding the persistent MIOpen find-db created by
`comfyui-init`).

Tags are moving (`latest` / `amd-latest`); pin a `vX.Y.Z` / `amd-vX.Y.Z` tag or
an image digest in `.env` for reproducible deployments. To use a different
image family (e.g. `yanwk/comfyui-boot`, the most popular), only the `image:`
values and the container paths change — the profiles, volumes and proxy contract
stay the same.

Drag-drop workflows and per-use-case node guides live in
[`WORKFLOWS.md`](WORKFLOWS.md) — start with basic image generation.

## Operational notes

- `restart: unless-stopped` everywhere except the one-shot `models-init`,
  `invokeai-init` and `comfyui-init` (`restart: "no"`).
- No `container_name:` — Compose default naming keeps services scalable.
- Config changes to the bridge data dir do not apply to an existing
  `bridge-data` volume; remove service + volume to reseed (see
  [`openai-bridge/README.md`](openai-bridge/README.md)).
- The bridge's `sdxl-txt2img.json` workflow and `registry.json` are plain JSON
  templates tracked in `openai-bridge/templates/` and baked into the image. On
  first start they are seeded into `bridge-data`, and the bridge auto-discovers
  the SDXL model reference from InvokeAI (`/api/v2/models/`, `base=sdxl`,
  `type=main`) — no build args, no manual model config. Discovery runs once and
  is never refreshed; `BRIDGE_MODEL_WAIT_SECONDS` caps the first-run wait — see
  [Workflow templates](openai-bridge/README.md#workflow-templates).
- Stamp builds with a date if you want a traceable image:
  `BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) docker compose build`.
- The ComfyUI images run as root, so their data volumes
  (`comfyui-nodes`, `comfyui-user`, `comfyui-input`, `comfyui-output`,
  `comfyui-cache`) are root-owned; to reset one, remove the service's volume and
  `up -d` again.
- Homepage labels are set on all long-running services.

## Troubleshooting

### `CUDA unknown error` / `torch.cuda.is_available() == False` (NVIDIA)

On some hosts the Docker `--gpus`/device-request path (Compose
`deploy.resources.reservations.devices`) injects the GPU device nodes but leaves
CUDA unable to initialize (`cuInit` returns `CUDA_ERROR_UNKNOWN` / 999), while
`nvidia-smi` still works. The NVIDIA service therefore uses `runtime: nvidia`
with `NVIDIA_VISIBLE_DEVICES=all`, which initializes CUDA correctly. If you still
hit the error:

1. Register the toolkit runtime:
   `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`.
2. Probe the driver API directly, bypassing InvokeAI:
   `docker run --rm --runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all python:3.12-slim python -c "import ctypes;print(ctypes.CDLL('libcuda.so.1').cuInit(0))"` — expect `0`.
3. If it returns `999`, the host driver/toolkit is at fault: regenerate the CDI
   spec, confirm the running kernel module matches `nvidia-utils`, and reboot
   after driver updates.

### AMD / ROCm (ROCm 7.2 derivative)

The upstream `main-rocm` image ships the ROCm 7.1 torch stack, which SIGSEGVs
(`exit 139`) on gfx1151 (Strix Halo / Radeon 8060S) at the first GPU operation:
ROCm 7.1 computes an incorrect VGPR count for gfx1151 (`ROCm/TheRock#2991`,
`pytorch/pytorch#173367`). `torch.cuda.is_available()` returns `True` and
`gfx1151` is in `torch.cuda.get_arch_list()`, so the fault is easy to
misdiagnose; no `HSA_OVERRIDE_GFX_VERSION` / `HSA_ENABLE_SDMA` setting fixes it.

`invokeai-rocm/Dockerfile` builds a thin derivative of the upstream image and
reinstalls torch/torchvision/torchaudio/triton-rocm from PyTorch's ROCm 7.2 wheel
index (the torch 2.11.0 line), which bundles the fixed runtime. `docker compose --profile
amd up` builds it automatically; bump `INVOKEAI_ROCM_VERSION` to move ROCm
versions, or delete the Dockerfile and go back to a plain upstream `image:` once
`main-rocm` ships ROCm >= 7.2 (InvokeAI issue #9130).

Verify the swap inside the running container:

```sh
COMPOSE_PROFILES=amd docker compose exec invokeai-amd python -c \
  "import torch; print(torch.__version__, torch.version.hip)"
```

Expect a `+rocm7.2` build rather than `+rocm7.1`. The benign bitsandbytes
`rocminfo` warning (`No such file or directory: 'rocminfo'`) is unrelated and
can be ignored.

The AMD service also sets gfx1151 / APU performance variables:
`TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1` + `..._CACHE=1` (without AOTriton,
ROCm SDPA falls back to the very slow math path — the container logs a warning
asking for this), `TORCH_BLAS_PREFER_HIPBLASLT=1` (hipBLASLt is materially faster
than rocBLAS on gfx1151 inference GEMMs), `HSA_ENABLE_SDMA=0` (SDMA is unreliable
on APUs and can hang the VAE), and `MIOPEN_FIND_MODE=HYBRID` with
`MIOPEN_USER_DB_PATH` / `MIOPEN_CUSTOM_CACHE_DIR` under `/invokeai` so the
compiled-kernel find-db persists in the `invokeai-root` volume. The first
generation after the database is built is slow (MIOpen compiles/tunes conv
kernels once); later generations — and later restarts — reuse it. Verify
hipBLASLt is active with:

```sh
COMPOSE_PROFILES=amd docker compose exec invokeai-amd python -c \
  "import torch; print(torch.backends.cuda.preferred_blas_library())"
```

Expect `Cublaslt`, not `Cublas`. On gfx1151 the realistic SDXL 1024² / 30-step
band is roughly 15-20 s (about 6-8x behind an RTX 5090); the gap is memory
bandwidth and compute, not configuration.

## Agent usage example

```python
import base64
from openai import OpenAI

client = OpenAI(
    base_url="https://images.example.com/v1",   # images.${BASE_DOMAIN}
    api_key="<BRIDGE_API_KEY>",
)

result = client.images.generate(
    model="<registry id from /admin>",          # see openai-bridge/README.md
    prompt="a red fox in a snowy forest, cinematic",
    size="1024x1024",
    n=1,
    response_format="b64_json",                 # the bridge only supports b64_json
)
with open("fox.png", "wb") as f:
    f.write(base64.b64decode(result.data[0].b64_json))
```

The bridge returns `b64_json` only (any other `response_format` is rejected),
and `model` must match a registry id configured in `/admin` — not an InvokeAI
checkpoint name.

See [Using the bridge from an agent](openai-bridge/README.md#using-the-bridge-from-an-agent)
for the full contract plus the zero-dependency helper script
(`openai-bridge/examples/generate-image.sh`) and drop-in opencode /
oh-my-opencode-slim examples.

## Security notes

- The bridge requires `Authorization: Bearer <BRIDGE_API_KEY>` on every
  `/v1/*` call; `/healthz` is intentionally unauthenticated.
- The bridge `/admin` UI is protected by HTTP Basic
  (`BRIDGE_ADMIN_USER` / `BRIDGE_ADMIN_PASS`).
- `.env` holds all secrets and is gitignored; track `env.example` instead.
- InvokeAI is a single-user application and must stay private — do not expose
  it directly to untrusted networks or attempt multi-tenant use.
