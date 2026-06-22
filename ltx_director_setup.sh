#!/usr/bin/env bash
#
# LTX Director — full ComfyUI setup (idempotent / resumable)
# Updates ComfyUI, installs/updates custom nodes, pulls workflows, downloads models.
#
# Usage:
#   bash ltx_director_setup.sh           # skips steps already completed
#   bash ltx_director_setup.sh --force   # re-runs every step from scratch
#
set -uo pipefail   # NOTE: no -e — we want to continue past individual failures

COMFY=/workspace/ComfyUI
STATE="$COMFY/.setup_state"          # marker files live here, on the persistent volume
mkdir -p "$STATE"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1 && echo "[--force] ignoring existing markers"

log()  { echo -e "\n=== $* ==="; }

# done <step-name>  -> true if step already completed (and not forcing)
is_done() { [ "$FORCE" -eq 0 ] && [ -f "$STATE/$1.done" ]; }
# mark <step-name>  -> record step as completed
mark() { touch "$STATE/$1.done"; }

# run_step <step-name> <description> <function>
# Skips if marked done; runs the function and marks it on success.
run_step() {
  local name="$1" desc="$2" fn="$3"
  if is_done "$name"; then
    echo "⏭  skipping (already done): $desc"
    return
  fi
  log "$desc"
  if "$fn"; then
    mark "$name"
  else
    echo "⚠  step '$name' returned non-zero — NOT marking done (will retry next run)"
  fi
}

# ---------------------------------------------------------------------------
# Step definitions
# ---------------------------------------------------------------------------

step_core() {
  cd "$COMFY" && git pull origin master && pip install -r requirements.txt
}

# clone_node <repo-url> <target-dir-name>
clone_node() {
  local url="$1" name="$2" dir="$COMFY/custom_nodes/$2"
  if [ -d "$dir/.git" ]; then
    echo "↻ $name exists — pulling latest"
    git -C "$dir" pull 2>&1 | tail -1
  else
    echo "↓ cloning $name"
    git clone "$url" "$dir"
  fi
  [ -f "$dir/requirements.txt" ] && pip install -r "$dir/requirements.txt"
  return 0
}

step_nodes() {
  clone_node https://github.com/WhatDreamscost/WhatDreamsCost-ComfyUI WhatDreamsCost-ComfyUI
  clone_node https://github.com/kijai/ComfyUI-KJNodes              ComfyUI-KJNodes
}

step_workflow_deps() {
  cd "$COMFY"
  for wf in user/default/workflows/*.json; do
    [ -e "$wf" ] || continue
    echo "--- deps for: $wf"
    python custom_nodes/ComfyUI-Manager/cm-cli.py deps-in-workflow \
      --workflow "$wf" --output /tmp/deps.json \
    && python custom_nodes/ComfyUI-Manager/cm-cli.py install-deps /tmp/deps.json
  done
  return 0
}

step_update_nodes() {
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
  return 0
}

step_example_workflows() {
  cd "$COMFY/user/default/workflows" && \
    npx --yes degit WhatDreamsCost/WhatDreamsCost-ComfyUI/example_workflows --force
}

# download <folder> <filename> <url>  (skips if file already present & non-empty)
download() {
  local dir="$1" file="$2" url="$3"
  mkdir -p "$dir"
  if [ -s "$dir/$file" ]; then
    echo "✓ exists, skipping: $file"
  else
    echo "↓ downloading: $file"
    wget -c --tries=3 -O "$dir/$file" "$url" || { echo "✗ FAILED: $file"; return 1; }
  fi
}

step_models() {
  local ok=0
  # diffusion models
  download "$COMFY/models/diffusion_models" \
    "ltx-2.3-22b-distilled-1.1_transformer_only_fp8_scaled.safetensors" \
    "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/diffusion_models/ltx-2.3-22b-distilled-1.1_transformer_only_fp8_scaled.safetensors" || ok=1
  # latent upscale models
  download "$COMFY/models/latent_upscale_models" \
    "ltx-2.3-spatial-upscaler-x2-1.1.safetensors" \
    "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-spatial-upscaler-x2-1.1.safetensors" || ok=1
  # vae
  download "$COMFY/models/vae" \
    "LTX23_audio_vae_bf16.safetensors" \
    "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/vae/LTX23_audio_vae_bf16.safetensors" || ok=1
  download "$COMFY/models/vae" \
    "LTX23_video_vae_bf16.safetensors" \
    "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/vae/LTX23_video_vae_bf16.safetensors" || ok=1
  download "$COMFY/models/vae" \
    "taeltx2_3.safetensors" \
    "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/vae/taeltx2_3.safetensors" || ok=1
  # text encoders
  download "$COMFY/models/text_encoders" \
    "ltx-2.3_text_projection_bf16.safetensors" \
    "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/text_encoders/ltx-2.3_text_projection_bf16.safetensors" || ok=1
  download "$COMFY/models/text_encoders" \
    "gemma_3_12B_it_fp4_mixed.safetensors" \
    "https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors" || ok=1
  # only mark done if EVERY file is present — a failed download leaves the step un-marked
  return $ok
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
run_step core             "Updating ComfyUI core"                step_core
run_step nodes            "Cloning / updating required nodes"    step_nodes
run_step workflow_deps    "Installing workflow dependencies"     step_workflow_deps
run_step update_nodes     "Updating installed custom nodes"      step_update_nodes
run_step example_wf       "Pulling example workflows"            step_example_workflows
run_step models           "Downloading models"                   step_models

# Always restart at the end (cheap, and we want fresh state after any change)
log "Restarting ComfyUI"
supervisorctl restart comfyui

log "Done.  (markers in $STATE — delete one to re-run that step, or pass --force)"
