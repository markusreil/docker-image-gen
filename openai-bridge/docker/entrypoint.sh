#!/bin/sh
# openai-bridge entrypoint: first-run seed + PUID/PGID privilege drop.
# POSIX sh, runs as root, then execs the proxy as the unprivileged user.
set -eu

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

TEMPLATES=/usr/local/share/openai-bridge/templates
DATA_DIR="${PROXY_DATA_DIR:-/data}"

# Workflows just seeded with an empty model reference (space-separated names).
PENDING=""

# Recreate the bridge group/user with the requested IDs when they differ.
ensure_bridge_user() {
    EXISTING_UID="$(id -u bridge 2>/dev/null || true)"
    EXISTING_GID="$(awk -F: '$1 == "bridge" { print $3 }' /etc/group 2>/dev/null || true)"

    if [ -n "$EXISTING_UID" ] && [ "$EXISTING_UID" != "$PUID" ]; then
        # Drop the user first so the group can be removed if a rename is needed.
        deluser bridge 2>/dev/null || true
    fi
    if [ -n "$EXISTING_GID" ] && [ "$EXISTING_GID" != "$PGID" ]; then
        delgroup bridge 2>/dev/null || true
    fi

    if ! grep -q '^bridge:' /etc/group; then
        # Prefer the requested GID; fall back to any available system group.
        addgroup -S -g "$PGID" bridge 2>/dev/null || addgroup -S bridge
    fi

    if ! id -u bridge >/dev/null 2>&1; then
        adduser -S -D -H -u "$PUID" -G bridge bridge 2>/dev/null || adduser -S -D -H bridge
    fi
}

# Copy each workflow template only if absent (write-once); remember the ones
# that still need a model reference resolved.
seed_workflows() {
    PENDING=""
    for tmpl in "$TEMPLATES"/workflows/*; do
        [ -f "$tmpl" ] || continue
        name="$(basename "$tmpl")"
        dest="$DATA_DIR/workflows/$name"
        if [ ! -f "$dest" ]; then
            cp "$tmpl" "$dest"
            if [ "$(jq -r '.nodes.model_loader.model.key // ""' "$dest")" = "" ]; then
                PENDING="$PENDING $name"
            fi
        fi
    done
}

# Echo the InvokeAI model object whose base matches $1 and type is "main".
resolve_model_ref() {
    wget -qO- "${INVOKE_BASE}/api/v2/models/" \
        | jq -c --arg b "$1" '[.models[]|select(.base==$b and .type=="main")][0] // empty'
}

# Wait once for InvokeAI, then patch a resolved model reference into each
# freshly seeded workflow that needs one. Never fails the container.
patch_model_refs() {
    [ -n "$PENDING" ] || return 0

    INVOKE_BASE="${INVOKE_URL:-http://invokeai:9090}"
    WAIT_MAX="${BRIDGE_MODEL_WAIT_SECONDS:-180}"

    echo "openai-bridge: waiting up to ${WAIT_MAX}s for InvokeAI at ${INVOKE_BASE} ..." >&2
    waited=0
    ready=0
    while [ "$waited" -lt "$WAIT_MAX" ]; do
        if wget -qO- "${INVOKE_BASE}/api/v1/app/version" >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if [ "$ready" != "1" ]; then
        echo "WARN: openai-bridge: InvokeAI not ready after ${WAIT_MAX}s; leaving model placeholders in seeded workflows" >&2
        return 0
    fi

    for name in $PENDING; do
        dest="$DATA_DIR/workflows/$name"
        [ -f "$dest" ] || continue
        base="$(jq -r '.nodes.model_loader.model.base // "sdxl"' "$dest")"
        [ -n "$base" ] || base=sdxl
        ref="$(resolve_model_ref "$base")"
        if [ -n "$ref" ]; then
            if jq --argjson r "$ref" '.nodes.model_loader.model = ($r + {type:"main"})' "$dest" > "$dest.tmp" \
                && mv "$dest.tmp" "$dest"; then
                echo "openai-bridge: resolved model '$(jq -r '.nodes.model_loader.model.name' "$dest")' for $name" >&2
            else
                rm -f "$dest.tmp"
                echo "WARN: openai-bridge: failed to patch model reference into $name" >&2
            fi
        else
            echo "WARN: openai-bridge: no model with base '$base' and type 'main' found; leaving placeholders in $name" >&2
        fi
    done
}

# Seed registry.json on first start only: from the image template if present,
# else an empty registry.
seed_registry() {
    if [ ! -f "$DATA_DIR/registry.json" ]; then
        if [ -f "$TEMPLATES/registry.json" ]; then
            cp "$TEMPLATES/registry.json" "$DATA_DIR/registry.json"
        else
            printf '%s\n' '{"models":[]}' > "$DATA_DIR/registry.json"
        fi
    fi
}

main() {
    ensure_bridge_user

    # Ensure the proxy uses the same directory we seed even when PROXY_DATA_DIR
    # is not set explicitly (compose always sets it to /data; a bare
    # `docker run` would otherwise fall back to an unwritable
    # `$HOME/.invoke-openai-proxy`).
    PROXY_DATA_DIR="$DATA_DIR"
    export PROXY_DATA_DIR
    mkdir -p "$DATA_DIR/workflows"

    seed_workflows
    patch_model_refs
    seed_registry

    # Recursive chown: the data dir is small config (registry + workflow JSON),
    # so walking it is cheap and keeps seeded files writable by the dropped user.
    chown -R "$PUID:$PGID" "$DATA_DIR"

    # `--no-browser` is always passed (no env equivalent); everything else is env.
    exec su-exec "$PUID:$PGID" invoke-openai-proxy --no-browser
}

main "$@"
