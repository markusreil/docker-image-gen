# AGENTS.md — ongoing rules for local-image-ai

Short summary of the rules that stay relevant while working in this repo. See
[`README.md`](README.md) and [`openai-bridge/README.md`](openai-bridge/README.md)
for detail; see `/specs/COMPOSE-SPEC.md` for the full compose conventions.

## Configuration

- All per-deployment config lives in `.env` (hidden, **never tracked**). Track
  `env.example` and keep both files in the same order/shape; every variable
  keeps its own comment. Never scatter secrets into other files.
- Required variables use `${VAR:?}` so `docker compose config` fails fast.
  Optional variables use `${VAR:-default}` and are documented as optional.
- Group variables globally first, then `# --- <service> ---` sections matching
  compose service names.
- `BUILD_DATE` is build-time only (`${BUILD_DATE:-unknown}`); never add it to
  `.env` / `env.example`. `BASE_IMAGE` is hardcoded in the Dockerfile.

## Compose conventions

- Project name is set once via `name: local-image-ai`; **never** use
  `container_name:`.
- `COMPOSE_PROFILES=nvidia` (in `.env`) makes the NVIDIA GPU profile the
  default for `docker compose up`; switch with
  `COMPOSE_PROFILES=amd docker compose up` or an explicit
  `docker compose --profile nvidia|amd ...`.
- The NVIDIA InvokeAI variant uses `runtime: nvidia` +
  `NVIDIA_VISIBLE_DEVICES=all` (not a `deploy` device reservation): the Docker
  device-request path fails CUDA initialization on some hosts. Do not
  "simplify" it back to the `deploy` form.
- The AMD InvokeAI variant is built locally from `invokeai-rocm/Dockerfile`, a
  thin derivative of the upstream `main-rocm` image that swaps torch to
  PyTorch's self-contained ROCm 7.2 wheels (ROCm 7.1 SIGSEGVs on gfx1151 /
  Strix Halo). The base image and wheel versions stay hardcoded in the
  Dockerfile; `INVOKEAI_ROCM_VERSION` tags the built image. Remove the
  derivative once upstream ships ROCm >= 7.2.
- No `ports:` anywhere. Services join the external `web-proxy` network
  (`name: ${NGINX_PROXY_NETWORK:-web-proxy}`, `external: true`) and advertise
  with `expose:`. Start the proxy cluster first.
- Every proxied service declares the **complete** downstream contract:
  `VIRTUAL_HOST`, `VIRTUAL_PORT` when needed, `ACME_HOST`, and a
  `GEN_SELF_SIGNED_CERT` opt-in wired from `.env` with a `false` default.
  Never hardcode `true` or omit a contract var.
- Hostnames are anchored once in `x-hosts` and referenced via YAML aliases
  (`*host-invokeai`, `*host-bridge`); do not copy hostname literals.
- Use standard named volumes for stateful data (`invokeai-root`,
  `invokeai-models`, `ai-models`, `bridge-data`); avoid host bind mounts.
- `restart: unless-stopped` for long-running services; `restart: "no"` only
  for the one-shot `models-init` / `invokeai-init`.
- Set Homepage labels (`homepage.group/name/icon/href/description`) on
  long-running services; an empty icon/description renders as a blank card.

## Models

- InvokeAI owns its models on the `invokeai-models` volume at `/models`
  (`INVOKEAI_MODELS_DIR=/models`, outside `INVOKEAI_ROOT`). It is the single
  writer; never point `models_dir` at the ComfyUI-canonical tree. The one-shot
  `invokeai-init` chowns the volume top level to `PUID`/`PGID` and creates the
  persistent MIOpen cache dir: the upstream entrypoint only chowns
  `INVOKEAI_ROOT`, so without it `/models` stays root-owned and startup fails,
  and MIOpen would recompile convolution kernels on every restart.
- `ai-models` is ComfyUI's own store. `models-init` creates the
  ComfyUI-canonical layout and chowns **only the top level** (never
  `chown -R`). Keep the directory list and the non-recursive chown in sync.
- Future ComfyUI mounts `ai-models` at `/comfyui/models` and reads
  `invokeai-models` read-only via `extra_model_paths.yaml`.

## openai-bridge entrypoint and templates

- Workflow/registry templates are tracked as plain JSON in
  `openai-bridge/templates/` and baked into the image at
  `/usr/local/share/openai-bridge/templates` (no build args, no `envsubst`).
  Never add hand-edited workflow JSON to the `bridge-data` volume as the source
  of truth.
- On **first start only** the entrypoint copies `workflows/*` and
  `registry.json` into the data dir and, if a workflow's model ref is empty,
  resolves it from InvokeAI (`/api/v2/models/`, matching `base` + `type=main`)
  after a readiness poll bounded by `BRIDGE_MODEL_WAIT_SECONDS`. Existing
  volumes are never re-resolved or overwritten and discovery is not periodic;
  the runtime image ships `jq` for this.
- The entrypoint runs as root, recreates the `bridge` user/group to match
  `PUID`/`PGID`, chowns the data dir **recursively** (small config), then
  `exec su-exec "$PUID:$PGID" ... --no-browser`. No `config.toml` is seeded —
  all config comes from `PROXY_*` env vars.
- Changing models means a reseed (write-once seeding); keep the reseed
  procedure in `openai-bridge/README.md` current.

## Changelog

Keep `## [Unreleased]` in `CHANGELOG.md` current as changes are made, under the
standard subsections (`Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`,
`Security`). Newest first. Do not create release sections unless asked.

## Verification

```sh
cp -n env.example .env
docker compose config -q
docker compose --profile nvidia config -q
docker compose --profile amd config -q
docker compose build openai-bridge
docker compose --profile amd build invokeai-amd
```

Do **not** run `docker compose up` in verification: the external `web-proxy`
network belongs to a separate proxy cluster that may not exist.

## Adding ComfyUI later

Use the same pattern: a `comfyui-nvidia` / `comfyui-amd` pair under the
`nvidia` / `amd` profiles with a shared `x-comfyui-common` anchor, internal
network alias `comfyui`, hostname `<service>.${BASE_DOMAIN}` from `x-hosts`,
mount `ai-models:/comfyui/models`, and the full proxy contract. Update
`CHANGELOG.md` and `env.example` with any new variables.
