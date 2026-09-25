# local-image-ai

A local, self-hosted AI image-generation stack. Phase 1 ships the **InvokeAI
WebUI** for interactive use and an **OpenAI-compatible bridge** so agents and
OpenAI-API clients can generate images. **ComfyUI** will be added later without
changing this deployment's shape.

## Architecture

```
  agents / OpenAI SDK                you (browser)
        │                                 │
        │ https://images.<domain>/v1      │ https://invokeai.<domain>
        ▼                                 ▼
  ┌────────────────────────── external reverse-proxy cluster ──────────────────────────┐
  │                    (owns all public endpoints; no host ports here)                  │
  └───────────────┬───────────────────────────────────────────┬────────────────────────┘
                  │ web-proxy network                         │ web-proxy network
                  ▼                                           ▼
         ┌─────────────────┐   internal network       ┌──────────────────────┐
         │  openai-bridge  │ ───────────────────────▶ │  invokeai (nvidia|amd)│
         │   :8080         │   http://invokeai:9090   │       :9090           │
         └────────┬────────┘                          └───────────┬──────────┘
                  │ /data (bridge-data)                           │ /invokeai (invokeai-root)
                   │                                               │ /models (invokeai-models)
                   └───────────────────────────────────────────────┘
      invokeai-models = InvokeAI-managed models, single writer. ComfyUI will
      read it read-only later; ai-models (seeded by models-init) is ComfyUI's
      own canonical download store.
```

## Services

| Service | Profile | Image | Purpose |
| --- | --- | --- | --- |
| `models-init` | — (one-shot) | `alpine:3.22` | Creates the ComfyUI-canonical model layout in `ai-models`. |
| `invokeai-models-init` | — (one-shot) | `alpine:3.22` | Fixes `/models` ownership in `invokeai-models` before InvokeAI starts. |
| `invokeai-nvidia` | `nvidia` | `${INVOKEAI_IMAGE_CUDA}` | InvokeAI WebUI + API on NVIDIA GPUs. |
| `invokeai-amd` | `amd` | `${INVOKEAI_IMAGE_ROCM}` | InvokeAI WebUI + API on AMD GPUs (ROCm). |
| `openai-bridge` | — (always on) | built from `./openai-bridge` | OpenAI-compatible `/v1` bridge to InvokeAI. |

All state lives in named volumes: `invokeai-root`, `invokeai-models`,
`ai-models`, `bridge-data`.

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
  the `video` and `render` groups on the host. The service passes `/dev/kfd`
  and `/dev/dri` through and sets `shm_size: 8g`.
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
  `INVOKEAI_GEN_SELF_SIGNED_CERT` / `BRIDGE_GEN_SELF_SIGNED_CERT`.

Because both opt-ins are declared, the same compose file works in either proxy
variant; the proxy honours only the one that matches. **Start the proxy cluster
first** — its network is consumed as `external: true` here.

Hostnames are defined once in `x-hosts`:

- InvokeAI → `invokeai.${BASE_DOMAIN}`
- Bridge → `images.${BASE_DOMAIN}`

## Model storage

InvokeAI owns its models on a dedicated named volume, `invokeai-models`, mounted
at `/models` and configured with `INVOKEAI_MODELS_DIR=/models`. Keeping it
outside `INVOKEAI_ROOT` means the upstream entrypoint's recursive `chown` never
walks the model store, and the pool can later be mounted read-only into ComfyUI.
Because the entrypoint only chowns `INVOKEAI_ROOT`, a one-shot
`invokeai-models-init` service chowns the top level of `invokeai-models` to
`PUID`/`PGID` before InvokeAI starts (`CONTAINER_UID=${PUID:-1000}` keeps the
container's runtime user aligned).

- Models downloaded in the InvokeAI UI land in `invokeai-models` (one `<uuid>/`
  folder per model, tracked by InvokeAI's database).
- `ai-models` is a separate, ComfyUI-canonical volume seeded by `models-init`
  (`checkpoints`, `loras`, `vae`, ...). InvokeAI does **not** use it.
- To share bytes with the future ComfyUI, mount `invokeai-models` read-only into
  ComfyUI and list it in `extra_model_paths.yaml`. Do **not** point InvokeAI's
  `models_dir` at the ComfyUI tree: InvokeAI rewrites its managed dir (flat
  `<uuid>` layout) and `Sync Models` can recursively delete orphan folders.

Bulk-load ComfyUI-style models into `ai-models` with a one-off container:

```sh
docker run --rm -v local-image-ai_ai-models:/models -v "$PWD":/src alpine:3.22 \
  cp /src/my-model.safetensors /models/checkpoints/
```

(If the project directory is renamed, the volume prefix changes; check
`docker volume ls | grep ai-models`.)

## Adding ComfyUI later

The project is structured for it:

1. Add a `comfyui` service pair (`comfyui-nvidia`, `comfyui-amd`) using the
   same `nvidia` / `amd` profile pattern and a shared `x-comfyui-common` anchor.
2. Mount `ai-models` at `/comfyui/models` for ComfyUI's own downloads, and
   mount `invokeai-models` read-only (e.g. `/invoke-models:ro`) as an
   `extra_model_paths.yaml` source so InvokeAI's models are visible without
   duplication.
3. Give it the internal-network alias `comfyui` and the hostname
   `comfyui.${BASE_DOMAIN}` via the `x-hosts` anchor, with the same full proxy
   contract (no `ports:`).
4. Record the change in `CHANGELOG.md` and `env.example`.

## Operational notes

- `restart: unless-stopped` everywhere except the one-shot `models-init` and
  `invokeai-models-init` (`restart: "no"`).
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
- Homepage labels are set on both long-running services.

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
