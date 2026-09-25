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
so the entrypoint path is explicit. The build also renders the tracked workflow
templates (see [Workflow templates](#workflow-templates)) and uses a pinned
`golang:${GO_VERSION}-alpine` builder; the runtime is a minimal
`alpine:3.22` image (`su-exec` + `ca-certificates`) that receives only the
static binary and the rendered templates.

Build directly if needed (the `SDXL_MODEL_*` args default to placeholders if
omitted — see [Workflow templates](#workflow-templates)):

```sh
docker build \
  --build-arg BRIDGE_VERSION=v1.6 \
  --build-arg SDXL_MODEL_KEY=<key> \
  --build-arg SDXL_MODEL_NAME="<name>" \
  --build-arg SDXL_MODEL_HASH=<hash> \
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

## Data directory and model registry

`PROXY_DATA_DIR` (`/data`, backed by the `bridge-data` named volume) holds:

- `registry.json` — the model registry. Seeded once on first start from the
  rendered `registry.json` template.
- `workflows/` — workflow JSON files, seeded once on first start from the
  rendered workflow templates.
- `config.toml` — optional; normally absent because env vars take precedence.

Models are registered through the **`/admin` Quick Setup** flow, which writes
into `registry.json`. The `model` value in an OpenAI request must match a
registry id. This project ships a ready-made `sdxl` registry entry plus its
`sdxl-txt2img.json` workflow (see below), so no manual Quick Setup is needed.

## Workflow templates

Templates are tracked in the repo under `templates/` and **rendered at image
build time**, so what ends up in the container is reproducible from source
(no more hand-written files inside the `bridge-data` volume).

- `templates/workflows/sdxl-txt2img.json.tmpl` — the workflow graph.
- `templates/registry.json.tmpl` — the model registry entry.

Rendering uses `envsubst` restricted to exactly four build args, so no other
`${...}` in the templates is touched:

| Build arg | Compose variable | Purpose |
| --- | --- | --- |
| `SDXL_MODEL_KEY` | `SDXL_MODEL_KEY` | InvokeAI model `key` (UUID) of the SDXL main model. |
| `SDXL_MODEL_NAME` | `SDXL_MODEL_NAME` | Human-readable model name. |
| `SDXL_MODEL_HASH` | `SDXL_MODEL_HASH` | InvokeAI model hash (e.g. `blake3:...`). |
| `SDXL_MODEL_BASE` | `SDXL_MODEL_BASE` | Model base type (default `sdxl`). |

The rendered files are baked into the image at
`/usr/local/share/openai-bridge/templates/{workflows/,registry.json}` and seeded
into the data dir **on first start only** (the entrypoint never overwrites an
existing file).

### How to set the model reference

Get the values from InvokeAI's model API:

```sh
curl -s http://invokeai:9090/api/v2/models/   # or via the WebUI
```

Pick the entry with `"base": "sdxl"` and `"type": "main"` and copy its `key`,
`name`, and `hash` into `.env` (`SDXL_MODEL_KEY`, `SDXL_MODEL_NAME`,
`SDXL_MODEL_HASH`; leave `SDXL_MODEL_BASE=sdxl`). Then rebuild:

```sh
docker compose build openai-bridge
```

Compile-time values are baked into the image, so changing the model reference
requires a **rebuild** — and because seeding is write-once, it also requires a
reseed for an existing volume.

### Seed / reseed procedure

Seeding is first-run only, so an existing volume is never overwritten. To
re-seed `registry.json` and `workflows/` from the current image (for example
after changing the model reference):

```sh
docker compose rm -sf openai-bridge
docker volume rm local-image-ai_bridge-data
docker compose up -d openai-bridge
```

The entrypoint recreates `registry.json` and `workflows/` from the rendered
templates on the next start. Editing a workflow or the registry in place in the
volume is also possible, but such edits are lost on the next reseed.

## Entrypoint / privilege drop

The entrypoint runs as root, recreates the `bridge` user/group to match
`PUID`/`PGID`, creates the data dir and seeds `workflows/*` and `registry.json`
on first start only, then chowns the data dir **recursively** (the data dir is
small config, and the seeded files must be writable by the dropped user), then
`exec su-exec "$PUID:$PGID" invoke-openai-proxy --no-browser`.
