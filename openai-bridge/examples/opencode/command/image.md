---
description: Generate an image from a text prompt via the local openai-bridge
agent: build
---

Generate an image for the following request:

$ARGUMENTS

Steps:

1. Ensure `BRIDGE_URL` and `BRIDGE_API_KEY` are set. `BRIDGE_API_KEY` is the
   bridge `/v1` bearer token (the same value as `BRIDGE_API_KEY` in the project
   `.env`); `BRIDGE_URL` defaults to `http://localhost:8080/v1` and should be
   `https://images.<your-domain>/v1` when calling the public endpoint.
2. Run the helper script:

   ```sh
   openai-bridge/examples/generate-image.sh "<the user's prompt>"
   ```

   Optionally pass a size (`1024x1024`, `1792x1024`, or `1024x1792`), a registry
   model id (default `sdxl`), and an output path. `GET /v1/models` lists the
   available registry ids.
3. Report the absolute path of the saved PNG to the user.

Notes: the bridge only supports `response_format: "b64_json"` (there is no image
URL), and no edit workflow is registered — do not call `/v1/images/edits`.
