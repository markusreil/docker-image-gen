#!/bin/sh
# openai-bridge entrypoint: first-run seed + PUID/PGID privilege drop.
# POSIX sh, runs as root, then execs the proxy as the unprivileged user.
set -eu

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

# --- recreate the bridge group/user with the requested IDs when they differ ---
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

# --- first-run seed: rendered workflow templates + registry.json ---
# Templates are rendered at image build time and live read-only in the image.
# Seeding is write-once: an existing volume is never overwritten.
TEMPLATES=/usr/local/share/openai-bridge/templates
DATA_DIR="${PROXY_DATA_DIR:-/data}"
# Ensure the proxy uses the same directory we seed even when PROXY_DATA_DIR is
# not set explicitly (compose always sets it to /data; a bare `docker run`
# would otherwise fall back to an unwritable `$HOME/.invoke-openai-proxy`).
PROXY_DATA_DIR="$DATA_DIR"
export PROXY_DATA_DIR
mkdir -p "$DATA_DIR/workflows"

for tmpl in "$TEMPLATES"/workflows/*; do
    [ -f "$tmpl" ] || continue
    name="$(basename "$tmpl")"
    if [ ! -f "$DATA_DIR/workflows/$name" ]; then
        cp "$tmpl" "$DATA_DIR/workflows/$name"
    fi
done

if [ ! -f "$DATA_DIR/registry.json" ]; then
    if [ -f "$TEMPLATES/registry.json" ]; then
        cp "$TEMPLATES/registry.json" "$DATA_DIR/registry.json"
    else
        printf '%s\n' '{"models":[]}' > "$DATA_DIR/registry.json"
    fi
fi

# Recursive chown: the data dir is small config (registry + workflow JSON), so
# walking it is cheap and keeps seeded files writable by the dropped user.
chown -R "$PUID:$PGID" "$DATA_DIR"

# `--no-browser` is always passed (no env equivalent); everything else is env.
exec su-exec "$PUID:$PGID" invoke-openai-proxy --no-browser
