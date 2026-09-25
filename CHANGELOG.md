# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Tracked bridge workflow/registry templates under `openai-bridge/templates/`
  (`workflows/sdxl-txt2img.json.tmpl`, `registry.json.tmpl`), rendered at image
  build time with `envsubst` restricted to the `SDXL_MODEL_*` build args, so the
  seeded workflow and registry are reproducible from source instead of
  hand-written into the `bridge-data` volume.
- `SDXL_MODEL_KEY` / `SDXL_MODEL_NAME` / `SDXL_MODEL_HASH` / `SDXL_MODEL_BASE`
  compose build args (optional, wired from `.env` / `env.example`) and first-run
  seeding of `workflows/*` plus `registry.json` from the rendered templates.
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

### Fixed

- Corrected the `README.md` agent example to request `response_format: b64_json`
  and decode `data[0].b64_json` (the bridge does not support image URLs).

### Security
