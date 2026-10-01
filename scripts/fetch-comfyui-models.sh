#!/usr/bin/env bash
# fetch-comfyui-models.sh — fetch public ComfyUI SDXL models into the ai-models volume.
#
# NOTE: volume prefix changes if the project dir is renamed; check with:
#   docker volume ls | grep ai-models
#
# Usage:
#   scripts/fetch-comfyui-models.sh [--volume NAME] [--dry-run] [--force]
#     [--skip-faceid] [--skip-reactor] [--skip-pulid]
#
# Idempotent: skips files already present in the volume unless --force.
# Never writes secrets / tokens.
set -euo pipefail

VOLUME="${VOLUME:-image-ai_ai-models}"
DRY_RUN=0
FORCE=0
SKIP_FACEID=0
SKIP_REACTOR=0
SKIP_PULID=0

while [ $# -gt 0 ]; do
  case "$1" in
    --volume) VOLUME="$2"; shift 2 ;;
    --volume=*) VOLUME="${1#--volume=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --skip-faceid) SKIP_FACEID=1; shift ;;
    --skip-reactor) SKIP_REACTOR=1; shift ;;
    --skip-pulid) SKIP_PULID=1; shift ;;
    -h|--help) sed -n '1,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

CURL_IMG="curlimages/curl:latest"

# dest|url pairs (dest relative to /models)
ITEMS=""

add() { ITEMS="$ITEMS$1|$2
"; }

add "controlnet/xinsir-controlnet-openpose-sdxl-1.0.safetensors" \
  "https://huggingface.co/xinsir/controlnet-openpose-sdxl-1.0/resolve/main/diffusion_pytorch_model.safetensors"
[ "$SKIP_PULID" -eq 0 ] && add "pulid/ip-adapter_pulid_sdxl_fp16.safetensors" \
  "https://huggingface.co/huchenlei/ipadapter_pulid/resolve/main/ip-adapter_pulid_sdxl_fp16.safetensors"
for f in 1k3d68.onnx 2d106det.onnx genderage.onnx glintr100.onnx scrfd_10g_bnkps.onnx; do
  add "insightface/models/antelopev2/$f" \
    "https://huggingface.co/MonsterMMORPG/tools/resolve/main/$f"
done
if [ "$SKIP_FACEID" -eq 0 ]; then
  add "ipadapter/ip-adapter-faceid-plusv2_sdxl.bin" \
    "https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/ip-adapter-faceid-plusv2_sdxl.bin"
  add "loras/ip-adapter-faceid-plusv2_sdxl_lora.safetensors" \
    "https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main/ip-adapter-faceid-plusv2_sdxl_lora.safetensors"
  add "clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors" \
    "https://huggingface.co/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors"
fi
if [ "$SKIP_REACTOR" -eq 0 ]; then
  add "insightface/inswapper_128.onnx" \
    "https://huggingface.co/datasets/Gourieff/ReActor/resolve/main/models/inswapper_128.onnx"
  add "ultralytics/bbox/face_yolov8m.pt" \
    "https://huggingface.co/datasets/Gourieff/ReActor/resolve/main/models/detection/bbox/face_yolov8m.pt"
fi

# buffalo_l.zip: auto-fetched by nodes on first run; best-effort here.
add "insightface/models/buffalo_l.zip" \
  "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip"

echo "Volume: $VOLUME"
[ "$DRY_RUN" -eq 1 ] && echo "(dry-run: listing only)"
printf '%s' "$ITEMS" | while IFS='|' read -r dest url; do
  [ -z "$dest" ] && continue
  echo "  $dest <- $url"
done

if [ "$DRY_RUN" -eq 1 ]; then
  :
else
  # Ensure dirs exist in volume.
  docker run --rm -v "$VOLUME":/models alpine sh -c \
    "mkdir -p /models/controlnet /models/pulid /models/insightface/models/antelopev2 /models/ipadapter /models/loras /models/clip_vision /models/insightface /models/ultralytics/bbox /models/checkpoints"

  printf '%s' "$ITEMS" | while IFS='|' read -r dest url; do
    [ -z "$dest" ] && continue
    exists="$(docker run --rm -v "$VOLUME":/models alpine sh -c \
      "[ -s '/models/$dest' ] && echo yes || echo no")"
    if [ "$exists" = "yes" ] && [ "$FORCE" -eq 0 ]; then
      echo "skip (exists): $dest"
      continue
    fi
    echo "fetch: $dest"
    if [ "$dest" = "insightface/models/buffalo_l.zip" ]; then
      docker run --rm --user 0:0 -v "$VOLUME":/models "$CURL_IMG" \
        -fSL --retry 2 -o "/models/$dest" "$url" \
        || echo "WARN: buffalo_l.zip fetch failed (nodes fetch it on first run); continuing." >&2
    else
      docker run --rm --user 0:0 -v "$VOLUME":/models "$CURL_IMG" \
        -fSL --retry 3 -o "/models/$dest" "$url"
    fi
  done
fi

# Gated checkpoints: cannot auto-fetch (login-gated Civitai).
if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry-run: skipping checkpoint presence check."
else
  count="$(docker run --rm -v "$VOLUME":/models alpine sh -c \
    "ls /models/checkpoints/*.safetensors 2>/dev/null | wc -l")"
  if [ "${count:-0}" -eq 0 ]; then
    cat <<EOF
MISSING gated checkpoints in /models/checkpoints (Juggernaut XL v8 — Civitai 133005,
RealVisXL V5 — Civitai 139562). Download manually, then copy in, e.g.:
  docker run --rm -v $VOLUME:/models -v "\$PWD":/src alpine cp /src/<file>.safetensors /models/checkpoints/
EOF
  else
    echo "checkpoints present: $count file(s)."
  fi
fi
