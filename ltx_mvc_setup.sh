#!/usr/bin/env bash
#
# LTX 2.3 Music Video Creator V5.1 (AIO) — full ComfyUI setup (idempotent / resumable)
# Updates ComfyUI, installs/updates custom nodes, pulls the 3 AIO workflows, downloads models.
#
# The three "all-in-one" workflows set up by this script (vrgamedevgirl / vrgamegirl19):
#   1. LTX2.3_Music_Video_Creator_Prompt_Creator_V5.json   (run this FIRST)
#   2. LTX2.3_Music_Video_Creator_T2V_V5.1.json
#   3. LTX2.3_Music_Video_Creator_I2V_V5.1.json
#
# Usage:
#   bash ltx_mvc_setup.sh           # skips steps already completed
#   bash ltx_mvc_setup.sh --force   # re-runs every step from scratch
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
  # vrgamedevgirl nodes (the music-video creator + film grain / color match / enhance)
  clone_node https://github.com/vrgamegirl19/comfyui-vrgamedevgirl comfyui-vrgamedevgirl
  # Impact Pack — required for auto-queue
  clone_node https://github.com/ltdrdata/ComfyUI-Impact-Pack       ComfyUI-Impact-Pack
  # ComfyUI-GGUF — required to load the LTX 2.3 GGUF transformer
  clone_node https://github.com/city96/ComfyUI-GGUF                ComfyUI-GGUF
  # KJNodes — commonly used helper nodes in LTX workflows
  clone_node https://github.com/kijai/ComfyUI-KJNodes              ComfyUI-KJNodes
  # llama-cpp-python — required by the Prompt Creator workflow's local LLM
  pip install llama-cpp-python
  return 0
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

# Pull the three AIO workflows straight from the vrgamedevgirl repo folder.
step_workflows() {
  local dir="$COMFY/user/default/workflows"
  local base="https://raw.githubusercontent.com/vrgamegirl19/comfyui-vrgamedevgirl/main/Workflows/LTX-2_Workflows/LTX%202.3%20Music%20Video%20Creator%20V5.1"
  mkdir -p "$dir"
  local ok=0
  wget -O "$dir/LTX2.3_Music_Video_Creator_Prompt_Creator_V5.json" "$base/LTX2.3_Music_Video_Creator_Prompt_Creator_V5.json" || ok=1
  wget -O "$dir/LTX2.3_Music_Video_Creator_T2V_V5.1.json"          "$base/LTX2.3_Music_Video_Creator_T2V_V5.1.json"          || ok=1
  wget -O "$dir/LTX2.3_Music_Video_Creator_I2V_V5.1.json"          "$base/LTX2.3_Music_Video_Creator_I2V_V5.1.json"          || ok=1
  return $ok
}

# Audio stitching needs ffmpeg. Best-effort install (won't fail the step if unavailable).
step_ffmpeg() {
  if command -v ffmpeg >/dev/null 2>&1; then
    echo "✓ ffmpeg already installed"
  else
    echo "↓ installing ffmpeg"
    apt-get update && apt-get install -y ffmpeg || echo "⚠ could not apt-get ffmpeg — install it manually"
  fi
  return 0
}

# download <folder> <filename> <url>  (skips if file already present & non-empty)
download() {
  local dir="$1" file="$2" url="$3"
  mkdir -p "$dir"
  if [ "$url" = "PLACEHOLDER" ]; then
    echo "✗ PLACEHOLDER url for: $file — edit this script with the correct link, then re-run"
    return 1
  fi
  if [ -s "$dir/$file" ]; then
    echo "✓ exists, skipping: $file"
  else
    echo "↓ downloading: $file"
    wget -c --tries=3 -O "$dir/$file" "$url" || { echo "✗ FAILED: $file"; return 1; }
  fi
}

step_models() {
  local ok=0

  # --- diffusion models -----------------------------------------------------
  # Z-Image Turbo (used by the I2V workflow for the still-image generation stage)
  download "$COMFY/models/diffusion_models" \
    "z_image_turbo_bf16.safetensors" \
    "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors" || ok=1

  # --- unet (GGUF) ----------------------------------------------------------
  # LTX 2.3 22B distilled transformer, Q6_K GGUF (loaded by the ComfyUI-GGUF Unet loader)
  download "$COMFY/models/unet" \
    "LTX-2.3-22B-distilled-1.1-Q6_K.gguf" \
    "https://huggingface.co/QuantStack/LTX-2.3-GGUF/resolve/main/LTX-2.3-distilled-1.1/LTX-2.3-22B-distilled-1.1-Q6_K.gguf" || ok=1

  # --- vae ------------------------------------------------------------------
  download "$COMFY/models/vae" \
    "LTX23_audio_vae_bf16.safetensors" \
    "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/vae/LTX23_audio_vae_bf16.safetensors" || ok=1
  download "$COMFY/models/vae" \
    "LTX23_video_vae_bf16.safetensors" \
    "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/vae/LTX23_video_vae_bf16.safetensors" || ok=1
  # Z-Image VAE
  download "$COMFY/models/vae" \
    "ae.safetensors" \
    "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors" || ok=1
  # LTX audio vocoder — NOTE: this exact bundled filename is not published as a
  # standalone download (see Lightricks/LTX-2 issue #200). Folder may also need
  # adjusting. Replace PLACEHOLDER with the correct link if/when available.
  download "$COMFY/models/vae" \
    "ltx-av-step-1751000_vocoder_24K.safetensors" \
    "PLACEHOLDER" || ok=1

  # --- text encoders --------------------------------------------------------
  download "$COMFY/models/text_encoders" \
    "ltx-2.3_text_projection_bf16.safetensors" \
    "https://huggingface.co/Kijai/LTX2.3_comfy/resolve/main/text_encoders/ltx-2.3_text_projection_bf16.safetensors" || ok=1
  # Z-Image text encoder (Qwen3 4B)
  download "$COMFY/models/text_encoders" \
    "qwen_3_4b.safetensors" \
    "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors" || ok=1
  # LTX 2.3 Gemma text encoder — Sikaworld abliterated "high fidelity" edition
  download "$COMFY/models/text_encoders" \
    "gemma-3-12b-it-abliterated-sikaworld-high-fidelity-edition.safetensors" \
    "https://huggingface.co/Sikaworld1990/gemma-3-12b-it-abliterated-sikaworld-high-fidelity-edition-Ltx-2/resolve/main/gemma-3-12b-it-abliterated-sikaworld-high-fidelity-edition.safetensors" || ok=1
  # (Gemma 12B LLM GGUF — see the LLM section below, kept with its matching mmproj.)

  # --- latent upscale models ------------------------------------------------
  download "$COMFY/models/latent_upscale_models" \
    "ltx-2.3-spatial-upscaler-x2-1.1.safetensors" \
    "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-spatial-upscaler-x2-1.1.safetensors" || ok=1
  download "$COMFY/models/latent_upscale_models" \
    "ltx-2-spatial-upscaler-x2-1.0.safetensors" \
    "https://huggingface.co/Lightricks/LTX-2/resolve/main/ltx-2-spatial-upscaler-x2-1.0.safetensors" || ok=1

  # --- LLM (Prompt Creator workflow, via llama-cpp-python) ------------------
  # Folder convention may differ depending on the vrgamedevgirl LLM node — adjust if needed.
  download "$COMFY/models/LLM" \
    "supergemma4-26b-uncensored-fast-v2-Q4_K_M.gguf" \
    "https://huggingface.co/Jiunsong/supergemma4-26b-uncensored-gguf-v2/resolve/main/supergemma4-26b-uncensored-fast-v2-Q4_K_M.gguf" || ok=1
  # Gemma 4 12B (QAT) LLM + its matching multimodal projector — used by the
  # Prompt Creator workflow's local vision LLM. mmproj MUST come from the same
  # repo as the base model so the projector matches.
  download "$COMFY/models/LLM" \
    "gemma-4-12B-it-qat-UD-Q4_K_XL.gguf" \
    "https://huggingface.co/unsloth/gemma-4-12B-it-qat-GGUF/resolve/main/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf" || ok=1
  download "$COMFY/models/LLM" \
    "mmproj-BF16.gguf" \
    "https://huggingface.co/unsloth/gemma-4-12B-it-qat-GGUF/resolve/main/mmproj-BF16.gguf" || ok=1

  # only mark done if EVERY file is present — a failed/PLACEHOLDER download leaves the step un-marked
  return $ok
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
run_step core             "Updating ComfyUI core"                step_core
run_step nodes            "Cloning / updating required nodes"    step_nodes
run_step workflows        "Pulling the 3 AIO workflows"          step_workflows
run_step workflow_deps    "Installing workflow dependencies"     step_workflow_deps
run_step update_nodes     "Updating installed custom nodes"      step_update_nodes
run_step ffmpeg           "Ensuring ffmpeg is installed"         step_ffmpeg
run_step models           "Downloading models"                   step_models

# Always restart at the end (cheap, and we want fresh state after any change)
log "Restarting ComfyUI"
supervisorctl restart comfyui

log "Done.  (markers in $STATE — delete one to re-run that step, or pass --force)"
