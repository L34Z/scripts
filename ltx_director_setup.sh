#!/usr/bin/env bash
#
# LTX Director — full ComfyUI setup
# Updates ComfyUI, installs/updates custom nodes, pulls workflows, downloads models.
#
# Usage:  bash ltx_director_setup.sh
#
set -uo pipefail   # NOTE: no -e — we want to continue past individual failures

COMFY=/workspace/ComfyUI
log() { echo -e "\n=== $* ==="; }

# ---------------------------------------------------------------------------
# 1. Update ComfyUI core
# ---------------------------------------------------------------------------
log "Updating ComfyUI core"
cd "$COMFY" && git pull origin master && pip install -r requirements.txt

# ---------------------------------------------------------------------------
# 2. Clone WhatDreamsCost custom node (skip if already present)
# ---------------------------------------------------------------------------
log "Cloning WhatDreamsCost-ComfyUI"
if [ -d "$COMFY/custom_nodes/WhatDreamsCost-ComfyUI" ]; then
  echo "Already cloned — skipping."
else
  git clone https://github.com/WhatDreamscost/WhatDreamsCost-ComfyUI \
    "$COMFY/custom_nodes/WhatDreamsCost-ComfyUI"
fi

# ---------------------------------------------------------------------------
# 3. Install missing custom nodes for every workflow
# ---------------------------------------------------------------------------
log "Installing workflow dependencies (custom nodes)"
cd "$COMFY"
for wf in user/default/workflows/*.json; do
  [ -e "$wf" ] || continue
  echo "--- deps for: $wf"
  python custom_nodes/ComfyUI-Manager/cm-cli.py deps-in-workflow \
    --workflow "$wf" --output /tmp/deps.json \
  && python custom_nodes/ComfyUI-Manager/cm-cli.py install-deps /tmp/deps.json
done

# ---------------------------------------------------------------------------
# 4. Update every installed custom node (skip detached HEAD)
# ---------------------------------------------------------------------------
log "Updating installed custom nodes"
cd "$COMFY/custom_nodes"
for d in */; do
  if [ -d "$d/.git" ]; then
    cd "$d"
    branch=$(git symbolic-ref --short HEAD 2>/dev/null)
    if [ -n "$branch" ]; then
      echo "Updating $d ($branch): $(git pull origin "$branch" 2>&1 | tail -1)"
    else
      echo "Skipping $d (detached HEAD)"
    fi
    cd ..
  fi
done

# ---------------------------------------------------------------------------
# 5. Pull example workflows
# ---------------------------------------------------------------------------
log "Pulling example workflows"
cd "$COMFY/user/default/workflows" && \
  npx --yes degit WhatDreamsCost/WhatDreamsCost-ComfyUI/example_workflows --force

# ---------------------------------------------------------------------------
# 6. Download models into their respective folders
# ---------------------------------------------------------------------------
log "Downloading models"

# folder | filename | url
download() {
  local dir="$1" file="$2" url="$3"
  mkdir -p "$dir"
  if [ -s "$dir/$file" ]; then
    echo "✓ exists, skipping: $file"
  else
    echo "↓ downloading: $file"
    # -c resume, -q quiet-ish but keep progress, retry on flaky connection
    wget -c --tries=3 -O "$dir/$file" "$url" \
      || echo "✗ FAILED: $file"
  fi
}

# diffusion models
download "$COMFY/models/diffusion_models" \
  "ltx-2.3-22b-distilled-1.1_transformer_only_fp8_scaled.safetensors" \
  "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/diffusion_models/ltx-2.3-22b-distilled-1.1_transformer_only_fp8_scaled.safetensors"

# latent upscale models
download "$COMFY/models/latent_upscale_models" \
  "ltx-2.3-spatial-upscaler-x2-1.1.safetensors" \
  "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-spatial-upscaler-x2-1.1.safetensors"

# vae
download "$COMFY/models/vae" \
  "LTX23_audio_vae_bf16.safetensors" \
  "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/vae/LTX23_audio_vae_bf16.safetensors"

download "$COMFY/models/vae" \
  "LTX23_video_vae_bf16.safetensors" \
  "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/vae/LTX23_video_vae_bf16.safetensors"

# text encoders
download "$COMFY/models/text_encoders" \
  "ltx-2.3_text_projection_bf16.safetensors" \
  "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/text_encoders/ltx-2.3_text_projection_bf16.safetensors"

download "$COMFY/models/text_encoders" \
  "gemma_3_12B_it_fp4_mixed.safetensors" \
  "https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors"

# ---------------------------------------------------------------------------
# 7. Restart ComfyUI
# ---------------------------------------------------------------------------
log "Restarting ComfyUI"
supervisorctl restart comfyui

log "Done."
