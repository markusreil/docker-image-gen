# Workflows

How to generate images with ComfyUI on this stack (`comfyui.${BASE_DOMAIN}`).

Drop any workflow JSON onto the canvas to load it. If nodes are missing,
ComfyUI Manager offers to install them. Generated files land in the
`comfyui-output` volume.

## Use cases

### 1. Basic image generation (text-to-image)

The minimal graph: checkpoint → prompts → noise → sampler → decode → save.

| Node | What it does | Typical settings |
| --- | --- | --- |
| `CheckpointLoaderSimple` | Loads a checkpoint and fans out `MODEL` (denoiser), `CLIP` (text encoder), `VAE` (pixel decoder). | Any SDXL checkpoint |
| `EmptyLatentImage` | Starting noise canvas. Dimensions = output resolution, `batch_size` = image count. | e.g. `1024×1024`, `832×1216`, batch `1` |
| `CLIPTextEncode` (positive) | Encodes the prompt into `CONDITIONING` the sampler steers toward. | Subject, style, framing, quality tags |
| `CLIPTextEncode` (negative) | Encodes what to avoid into `CONDITIONING` the sampler steers away from. | `blurry, deformed, watermark, text, cartoon` (adapt to model) |
| `KSampler` | Denoises the latent from `EmptyLatentImage` using `MODEL` + both conditionings. Core quality controls live here. | `steps` 25–35, `cfg` 5.0–7.5, sampler `dpmpp_2m` / scheduler `karras`, `denoise` 1.0 |
| `VAEDecode` | Decodes the finished latent to pixels using `VAE`. | — |
| `SaveImage` | Writes the PNG and shows it in the UI. | Filename prefix of your choice |

Connections: `MODEL → KSampler`, `CLIP → both CLIPTextEncodes → KSampler`,
`EmptyLatent → KSampler → VAEDecode (samples)`, `VAE → VAEDecode (vae)`,
`VAEDecode → SaveImage`.

**Run / tweak:**
- Queue once → one image. Keep `seed` on `fixed` while iterating on the
  prompt; switch to `randomize`/`increment` for variations.
- Resolution comes from `EmptyLatentImage`, not the sampler.
- If the image ignores the prompt, raise `cfg` slightly; if it looks
  overcooked, lower it. More `steps` helps detail up to ~30–35, then
  diminishing returns.
