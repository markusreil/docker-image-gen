---
name: image-generation
description: Generate or draw an image, picture, artwork, illustration, or render from a text prompt using the local OpenAI-compatible openai-bridge. Use this whenever the user asks to generate, draw, render, create, or illustrate an image, picture, artwork, or illustration.
---

# Image generation

Generate images locally by calling the helper script
`openai-bridge/examples/generate-image.sh`. It POSTs to the bridge's
OpenAI-compatible `/v1/images/generations` endpoint and saves the returned
base64 PNG.

## How to run

```sh
BRIDGE_URL="${BRIDGE_URL:-http://localhost:8080/v1}" \
BRIDGE_API_KEY="$BRIDGE_API_KEY" \
  openai-bridge/examples/generate-image.sh "<prompt>" [size] [model] [outfile]
```

- `BRIDGE_URL` defaults to `http://localhost:8080/v1`; use
  `https://images.<domain>/v1` for the public endpoint or
  `http://openai-bridge:8080/v1` on the compose internal network.
- `BRIDGE_API_KEY` is the bridge `/v1` bearer token and is required.
- `size`: `1024x1024` (default), `1792x1024`, or `1024x1792`.
- `model`: a **registry id**, not an InvokeAI checkpoint name. Defaults to
  `sdxl`. `GET $BRIDGE_URL/models` (with the Bearer token) lists registry ids.
- `outfile`: defaults to `image.png` in the current directory.

## Request contract

- Body: `{model, prompt, size, n: 1, response_format: "b64_json"[, negative_prompt]}`.
- `negative_prompt` is optional and supported for generation.
- Only `response_format: "b64_json"` is accepted — there is no image URL.
- **No edit workflow is registered**: do not call `/v1/images/edits` (or
  `/v1/images/variations`). Use generation only.

## Reporting

Always report the saved file path to the user.
