# syntax=docker/dockerfile:1
#
# openai-bridge — OpenAI-compatible API in front of InvokeAI.
#
# No upstream image exists, so we build the upstream Go proxy from source.
# The binary is built from ./cmd/proxy, named `proxy`; we rename it to
# `invoke-openai-proxy` to match the entrypoint and name the tool clearly.
#
# NOTE: upstream tags are of the form `v1.6`, not `v1.6.0`. Go's module
# resolver discards non-canonical tags (`semver.Canonical("v1.6") == "v1.6.0"`),
# so `go install .../cmd/proxy@v1.6` fails with "no matching versions".
# We therefore check out the tag with git, which resolves it correctly, and
# `go install ./cmd/proxy` from the checkout.

ARG GO_VERSION=1.26.3
FROM golang:${GO_VERSION}-alpine AS build

# Upstream tag to build (e.g. v1.6). Overridable at build time.
ARG BRIDGE_VERSION=v1.6
ARG BRIDGE_REPO=https://github.com/Pfannkuchensack/openaiapi2invokeai-go

# SDXL model reference used to render the workflow/registry templates at build
# time. Defaults are placeholders; compose passes the real values from `.env`.
ARG SDXL_MODEL_KEY=REPLACE_WITH_MODEL_KEY
ARG SDXL_MODEL_NAME=your-sdxl-model
ARG SDXL_MODEL_HASH=REPLACE_WITH_MODEL_HASH
ARG SDXL_MODEL_BASE=sdxl

RUN apk add --no-cache git \
    && git clone --quiet --branch "${BRIDGE_VERSION}" --depth 1 \
        "${BRIDGE_REPO}" /src \
    && cd /src \
    && CGO_ENABLED=0 GOBIN=/out go install ./cmd/proxy \
    && mv /out/proxy /out/invoke-openai-proxy \
    && rm -rf /src

# Render the tracked workflow/registry templates at build time. The envsubst
# variable list is explicit so only the four SDXL model-ref placeholders are
# substituted; any other `${...}` (e.g. in prompt text) is left untouched.
RUN apk add --no-cache gettext
COPY templates/ /templates/
RUN mkdir -p /out-templates/workflows \
    && for tmpl in /templates/workflows/*.tmpl; do \
         [ -f "$tmpl" ] || continue; \
         name="$(basename "$tmpl" .tmpl)"; \
         envsubst '${SDXL_MODEL_KEY} ${SDXL_MODEL_NAME} ${SDXL_MODEL_HASH} ${SDXL_MODEL_BASE}' \
           < "$tmpl" > "/out-templates/workflows/$name"; \
       done \
    && envsubst '${SDXL_MODEL_KEY} ${SDXL_MODEL_NAME} ${SDXL_MODEL_HASH} ${SDXL_MODEL_BASE}' \
         < /templates/registry.json.tmpl > /out-templates/registry.json

FROM alpine:3.22

# Documents the image this was built FROM (hardcoded, build-time only).
ENV BASE_IMAGE=alpine:3.22

# Build timestamp recorded in the image (passed via compose build.args).
ARG BUILD_DATE=unknown
ENV BUILD_DATE=${BUILD_DATE}

# su-exec drops privileges to PUID/PGID; ca-certificates for TLS to upstream.
RUN apk add --no-cache su-exec ca-certificates

# Build-time default user/group; the entrypoint recreates them to match PUID/PGID.
RUN addgroup -S bridge \
    && adduser -S -D -H -G bridge bridge

COPY --from=build /out/invoke-openai-proxy /usr/local/bin/invoke-openai-proxy
COPY --from=build /out-templates /usr/local/share/openai-bridge/templates
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod 0755 /usr/local/bin/invoke-openai-proxy /usr/local/bin/entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
