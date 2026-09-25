# openai-bridge

OpenAI-compatible HTTP bridge in front of InvokeAI, so agents and tools that
speak the OpenAI Images API can drive a local InvokeAI instance.

The service is `Pfannkuchensack/openaiapi2invokeai-go` (tag pinned by
`BRIDGE_VERSION`, default `v1.6`).

## Why this image builds from source

Upstream publishes **no Dockerfile and no image**, so the bridge is built from
source in this repository. The module's entry point lives at `./cmd/proxy`.

**Why the build clones the tag instead of `go install ...@${BRIDGE_VERSION}`:**
upstream tags look like `v1.6`, not `v1.6.0`. Go's module resolver drops
non-canonical tags (in `codeRepo.Versions`: `v != semver.Canonical(v)`), so
`go install github.com/Pfannkuchensack/openaiapi2invokeai-go/cmd/proxy@v1.6`
fails with `no matching versions for query "v1.6"` and `proxy.golang.org`
lists no versions for this module. `git` resolves the tag correctly, so the
build does:

```sh
git clone --branch "${BRIDGE_VERSION}" --depth 1 "${BRIDGE_REPO}" /src
cd /src && CGO_ENABLED=0 GOBIN=/out go install ./cmd/proxy
```

The resulting binary is named `proxy`; it is renamed to `invoke-openai-proxy`
so the entrypoint path is explicit. The build uses a pinned
`golang:${GO_VERSION}-alpine` builder; the runtime is a minimal `alpine:3.22`
image (`su-exec` + `ca-certificates` + `jq`) that receives the static binary and
the plain-JSON workflow templates (see
[Workflow templates](#workflow-templates)).

Build directly if needed:

```sh
docker build --build-arg BRIDGE_VERSION=v1.6 \
  -t local-image-ai/openai-bridge:v1.6 .
```

## Configuration

All behaviour is configured through `PROXY_*` environment variables — the
entrypoint deliberately seeds **no `config.toml`**, because the upstream config
precedence is `flag > env > config.toml > default`, so env vars fully drive it
and there is nothing to keep in sync.

| Variable | Default | Purpose |
| --- | --- | --- |
| `PROXY_LISTEN_IP` | `127.0.0.1` | Bind address inside the container (compose sets `0.0.0.0`). |
| `PROXY_PORT` | `8080` | Listen port. |
| `INVOKE_URL` | `http://127.0.0.1:9090` | Upstream InvokeAI base URL (compose sets `http://invokeai:9090`). |
| `PROXY_DATA_DIR` | `/data` | Holds `config.toml`, `registry.json` and workflow JSON files. |
| `PROXY_API_KEY` | empty | When set, every `/v1/*` request needs `Authorization: Bearer <key>`. |
| `PROXY_ADMIN_USER` | empty | With `PROXY_ADMIN_PASS`, enables HTTP Basic on `/admin*`. |
| `PROXY_ADMIN_PASS` | empty | Admin Basic-auth password. |
| `PROXY_TIMEOUT` | `300s` | Upstream request timeout (Go duration). |
| `PROXY_LOG_LEVEL` | `info` | Log verbosity. |
| `BRIDGE_MODEL_WAIT_SECONDS` | `180` | Cap (seconds) on the first-run wait for InvokeAI model discovery. |

`PUID` / `PGID` (default `1000:1000`) control the unprivileged user the proxy
runs as. The `--no-browser` flag is always passed by the entrypoint; it has no
environment equivalent (the container has no browser).

### Endpoints

- `GET /healthz` — no auth.
- `GET /v1/models` — Bearer auth when `PROXY_API_KEY` is set.
- `POST /v1/images/generations`, `/v1/images/edits`, `/v1/images/variations` — Bearer auth.
- `/admin` — HTTP Basic auth when `PROXY_ADMIN_USER` / `PROXY_ADMIN_PASS` are set.

## Auth and security reasoning

- **Bearer on `/v1/*`**: the proxy cluster exposes the bridge to the network,
  so generation endpoints must not be anonymous. `PROXY_API_KEY` is required by
  compose (`${BRIDGE_API_KEY:?}`), forbidding an empty/absent key.
- **Basic on `/admin*`**: the admin UI can change model configuration and
  issue test generations, so it is protected separately with
  `PROXY_ADMIN_USER` / `PROXY_ADMIN_PASS` (also required by compose).
- **No auth on `/healthz`**: it only reports liveness and exposes no state, so
  orchestrators/proxies can probe it.
- Administratively, InvokeAI itself must stay single-user/private — the bridge
  does not add multi-tenant isolation.

## Using the bridge from an agent

The bridge is a drop-in OpenAI Images endpoint for agents. The contract:

- **Base URL** — `https://images.<domain>/v1` (public) or
  `http://openai-bridge:8080/v1` on the compose `internal` network.
- **Auth** — `Authorization: Bearer <BRIDGE_API_KEY>` on every `/v1/*` request.
- **Models** — `GET /v1/models` lists registry ids. The `model` field in a
  request is a **registry id** (e.g. `sdxl`), not an InvokeAI checkpoint name.
- **Generate** — `POST /v1/images/generations` with
  `{model, prompt, size, n, response_format: "b64_json"[, negative_prompt]}`.
  Responses are **base64 only** (`.data[0].b64_json`); there is no `url`.
- **Sizes** — `1024x1024`, `1792x1024`, `1024x1792`.
- **Generation only** — the bridge exposes `/v1/images/edits` and
  `/v1/images/variations`, but the bundled `sdxl` entry defines no
  `edit_workflow` / `variant_workflow`, so those calls are not usable. Use
  `/v1/images/generations`.

### Zero-dependency helper

[`examples/generate-image.sh`](examples/generate-image.sh) needs only POSIX
shell, `curl`, `jq` and `base64`:

```sh
BRIDGE_URL=https://images.example.com/v1 BRIDGE_API_KEY=<token> \
  openai-bridge/examples/generate-image.sh "a red fox in a snowy forest" 1024x1024 sdxl fox.png
```

Usage: `generate-image.sh "<prompt>" [size] [model] [outfile]`; defaults are
`1024x1024`, `sdxl`, `image.png`.

### opencode

- **Custom command** — copy
  [`examples/opencode/command/image.md`](examples/opencode/command/image.md) to
  `.opencode/command/image.md` (project) or
  `~/.config/opencode/command/image.md` (global), then run `/image <prompt>`.
  It drives the helper script and reports the saved path.
- **Optional MCP route** — merge
  [`examples/opencode/opencode.mcp.example.json`](examples/opencode/opencode.mcp.example.json)
  into your `opencode.json`. This requires a separate MCP server that speaks the
  OpenAI Images API (the fragment sets `OPENAI_BASE_URL` / `OPENAI_API_KEY` with
  `{env:BRIDGE_API_KEY}` interpolation); the zero-dependency path is the helper
  script above.

Config changes require an opencode restart.

### oh-my-opencode-slim

- **Skill** — copy
  [`examples/oh-my-opencode-slim/skills/image-generation/SKILL.md`](examples/oh-my-opencode-slim/skills/image-generation/SKILL.md)
  to `~/.config/opencode/skills/image-generation/SKILL.md`.
- **Grant it** — the skill is enabled through the active preset's `skills`
  list in `~/.config/opencode/oh-my-opencode-slim.json[c]`: `["*"]` already
  includes it; an explicit list must add `"image-generation"`.
- **Optional custom agent** — see
  [`examples/oh-my-opencode-slim/oh-my-opencode-slim.example.jsonc`](examples/oh-my-opencode-slim/oh-my-opencode-slim.example.jsonc)
  for the preset skill grants plus a custom `imagegen` agent.

Config changes require an opencode restart.

## Data directory and model registry

`PROXY_DATA_DIR` (`/data`, backed by the `bridge-data` named volume) holds:

- `registry.json` — the model registry. Seeded once on first start from the
  baked-in `registry.json`.
- `workflows/` — workflow JSON files, seeded once on first start from the
  baked-in templates; the model reference is resolved from InvokeAI at that
  time.
- `config.toml` — optional; normally absent because env vars take precedence.

Models are registered through the **`/admin` Quick Setup** flow, which writes
into `registry.json`. The `model` value in an OpenAI request must match a
registry id. This project ships a ready-made `sdxl` registry entry plus its
`sdxl-txt2img.json` workflow (see below), so no manual Quick Setup is needed.

## Workflow templates

Templates are tracked in the repo as **plain JSON** under `templates/` and are
baked into the image at `/usr/local/share/openai-bridge/templates`:

- `templates/workflows/sdxl-txt2img.json` — the workflow graph, shipped with an
  empty model reference (`key`, `name` and `hash` blank; `base: "sdxl"`).
- `templates/registry.json` — the model registry entry (no model variables).

On first start the entrypoint copies each workflow into the data dir (only when
the destination does not exist) and, if its model reference is still empty,
resolves it from InvokeAI:

1. **Readiness wait** (lazy — only when a freshly seeded workflow needs a
   model): poll `GET ${INVOKE_URL}/api/v1/app/version` every 2s, up to
   `BRIDGE_MODEL_WAIT_SECONDS` seconds (default `180`).
2. **Resolve**: `GET ${INVOKE_URL}/api/v2/models/`, then select the first entry
   whose `base` matches the template's `.nodes.model_loader.model.base`
   (default `sdxl`) and whose `type` is `main`.
3. **Patch**: `jq --argjson r "$ref" '.nodes.model_loader.model = ($r + {type:"main"})'`.

Discovery happens **once, at startup, during first-run seeding only**. Existing
data volumes are never re-resolved or overwritten, and there is no periodic
refresh. The model reference is not a build arg and is not baked into the image.

If InvokeAI is not ready within the cap, or no matching model is found, the
entrypoint prints a `WARN:` to stderr and leaves the empty placeholders in
place; the container still starts. Generation then fails until a model
reference is set — either through `/admin` or by reseeding.

### Seed / reseed procedure

Seeding is first-run only. To re-seed `registry.json` and `workflows/` from the
current image — for example to re-run discovery after installing an SDXL model:

```sh
docker compose rm -sf openai-bridge
docker volume rm local-image-ai_bridge-data
docker compose up -d openai-bridge
```

The entrypoint copies the templates and re-resolves the model reference on the
next start. Editing a workflow or the registry in place in the volume is also
possible, but such edits are lost on the next reseed.

## Entrypoint / privilege drop

The entrypoint runs as root, recreates the `bridge` user/group to match
`PUID`/`PGID`, creates the data dir and seeds `workflows/*` and `registry.json`
on first start only (resolving the SDXL model reference from InvokeAI once, if
needed), then chowns the data dir **recursively** (the data dir is small config,
and the seeded files must be writable by the dropped user), then
`exec su-exec "$PUID:$PGID" invoke-openai-proxy --no-browser`.
