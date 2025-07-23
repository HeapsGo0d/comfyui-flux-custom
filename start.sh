#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log()   { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn()  { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"; }
error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"; }

# Trap for clean exit
exit_clean() {
    log "Received termination signal. Cleaning up..."
    jobs -p | xargs -r kill
    if [[ "$USE_VOLUME" == "true" ]]; then
        WORK_DIR="/runpod-volume"
    else
        WORK_DIR="/workspace"
    fi
    find "$WORK_DIR" -name "*.tmp" -delete 2>/dev/null || true
    find "$WORK_DIR" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    find "$WORK_DIR/logs" -name "*.log" -mtime +7 -delete 2>/dev/null || true
    log "Cleanup completed. Exiting..."
    exit 0
}
trap exit_clean SIGINT SIGTERM EXIT

# Determine working directory
if [[ "$USE_VOLUME" == "true" ]]; then
    WORK_DIR="/runpod-volume"
    log "Using persistent volume: $WORK_DIR"
    mkdir -p "$WORK_DIR"/{models/{checkpoints,loras,vae,unet,clip,diffusion_models,controlnet,pulid},input,output,logs}
    if [[ ! -d "$WORK_DIR/ComfyUI" ]]; then
        log "Copying ComfyUI to volume..."
        cp -r /workspace/external/hearmeman/* "$WORK_DIR/"
    fi
    cd "$WORK_DIR"
else
    WORK_DIR="/workspace/external/hearmeman"
    log "Using container workspace: $WORK_DIR"
    mkdir -p "$WORK_DIR/models"/{unet,clip,diffusion_models,controlnet,pulid}
    cd "$WORK_DIR"
fi

# HuggingFace CLI setup
setup_huggingface_cli() {
    if [[ -z "$HUGGINGFACE_TOKEN" ]]; then
        warn "HUGGINGFACE_TOKEN not set. Skipping HuggingFace model downloads."
        return 1
    fi
    log "Setting up HuggingFace CLI..."
    if ! python3 -c "import huggingface_hub" &> /dev/null; then
        log "Installing huggingface_hub..."
        pip install huggingface_hub[cli] || {
            error "Failed to install huggingface_hub"
            return 1
        }
    fi
    # FIXED: supply token directly
    huggingface-cli login --token "$HUGGINGFACE_TOKEN" --add-to-git-credential || {
        error "Failed to authenticate with HuggingFace"
        return 1
    }
    log "HuggingFace CLI setup completed successfully."
    return 0
}

# Download Flux/HF models
download_flux_models() {
    if [[ -z "$FLUX_MODEL_IDS_TO_DOWNLOAD" ]]; then
        log "No Flux model IDs specified. Skipping Flux downloads."
        return
    fi
    setup_huggingface_cli || { warn "Skipping Flux model downloads."; return; }
    log "Starting Flux model downloads..."
    IFS=',' read -ra IDS <<< "$FLUX_MODEL_IDS_TO_DOWNLOAD"
    for id in "${IDS[@]}"; do
        id="${id// /}"
        [ -z "$id" ] && continue
        log "Downloading Flux model: $id"
        if [[ "$id" == *"unet"* ]] || [[ "$id" == *"FLUX"* ]]; then
            dir="$WORK_DIR/models/unet"
        elif [[ "$id" == *"clip"* ]] || [[ "$id" == *"text"* ]]; then
            dir="$WORK_DIR/models/clip"
        else
            dir="$WORK_DIR/models/diffusion_models"
        fi
        huggingface-cli download "$id" \
            --local-dir "$dir/$(basename "$id")" \
            --local-dir-use-symlinks False \
            --resume-download || warn "Failed to download Flux model: $id"
    done
    log "Flux model downloads completed."
}

download_pulid_models() {
    [[ "$DOWNLOAD_PULID" != "true" ]] && { log "Skipping PuLID"; return; }
    setup_huggingface_cli || { warn "Skipping PuLID"; return; }
    log "Downloading PuLID models..."
    dir="$WORK_DIR/models/pulid"; mkdir -p "$dir"
    for id in "ToTheBeginning/PuLID" "guozinan/PuLID"; do
        log "Downloading PuLID: $id"
        huggingface-cli download "$id" \
            --local-dir "$dir/$(basename "$id")" \
            --local-dir-use-symlinks False \
            --resume-download || warn "Failed PuLID: $id"
    done
    log "PuLID downloads done."
}

download_flux_controlnet() {
    [[ "$DOWNLOAD_FLUX_CONTROLNET" != "true" ]] && { log "Skipping ControlNet"; return; }
    setup_huggingface_cli || { warn "Skipping ControlNet"; return; }
    log "Downloading Flux ControlNet..."
    dir="$WORK_DIR/models/controlnet"; mkdir -p "$dir"
    for id in \
      "black-forest-labs/FLUX.1-Canny-dev" \
      "black-forest-labs/FLUX.1-Depth-dev" \
      "InstantX/FLUX.1-dev-Controlnet-Canny" \
      "InstantX/FLUX.1-dev-Controlnet-Union"; do
        log "Downloading ControlNet: $id"
        huggingface-cli download "$id" \
            --local-dir "$dir/$(basename "$id")" \
            --local-dir-use-symlinks False \
            --resume-download || warn "Failed ControlNet: $id"
    done
    log "ControlNet downloads done."
}

download_flux_kontext() {
    [[ "$DOWNLOAD_FLUX_KONTEXT" != "true" ]] && { log "Skipping Kontext"; return; }
    setup_huggingface_cli || { warn "Skipping Kontext"; return; }
    log "Downloading Flux Kontext..."
    dir="$WORK_DIR/models/diffusion_models"; mkdir -p "$dir"
    for id in \
      "black-forest-labs/FLUX.1-Kontext-dev" \
      "black-forest-labs/FLUX.1-Kontext-pro" \
      "black-forest-labs/FLUX.1-Kontext-max"; do
        log "Downloading Kontext: $id"
        huggingface-cli download "$id" \
            --local-dir "$dir/$(basename "$id")" \
            --local-dir-use-symlinks False \
            --resume-download || warn "Failed Kontext: $id"
    done
    log "Kontext downloads done."
}

# Download CivitAI models
download_civitai_models() {
    [[ -z "$CIVITAI_TOKEN" ]] && { warn "No CIVITAI_TOKEN; skipping CivitAI"; return; }
    log "Starting CivitAI downloads..."
    if [[ -n "$CHECKPOINT_IDS_TO_DOWNLOAD" ]]; then
        log "Checkpoints..."
        IFS=',' read -ra IDS <<< "$CHECKPOINT_IDS_TO_DOWNLOAD"
        for id in "${IDS[@]}"; do
            id="${id// /}"
            [ -z "$id" ] && continue
            civitai-downloader --token "$CIVITAI_TOKEN" --model-id "$id" --output-dir "$WORK_DIR/models/checkpoints" \
                || warn "Failed checkpoint: $id"
        done
    fi
    if [[ -n "$LORA_IDS_TO_DOWNLOAD" ]]; then
        log "LoRAs..."
        IFS=',' read -ra IDS <<< "$LORA_IDS_TO_DOWNLOAD"
        for id in "${IDS[@]}"; do
            id="${id// /}"
            [ -z "$id" ] && continue
            civitai-downloader --token "$CIVITAI_TOKEN" --model-id "$id" --output-dir "$WORK_DIR/models/loras" \
                || warn "Failed LoRA: $id"
        done
    fi
    if [[ -n "$VAE_IDS_TO_DOWNLOAD" ]]; then
        log "VAEs..."
        IFS=',' read -ra IDS <<< "$VAE_IDS_TO_DOWNLOAD"
        for id in "${IDS[@]}"; do
            id="${id// /}"
            [ -z "$id" ] && continue
            civitai-downloader --token "$CIVITAI_TOKEN" --model-id "$id" --output-dir "$WORK_DIR/models/vae" \
                || warn "Failed VAE: $id"
        done
    fi
    log "CivitAI downloads done."
}

# Start FileBrowser
start_filebrowser() {
    if [[ "$FILEBROWSER" == "true" ]]; then
        log "Starting FileBrowser..."
        cat > /tmp/filebrowser.json << EOF
{
  "port": 8080,
  "baseURL": "",
  "address": "0.0.0.0",
  "log": "stdout",
  "database": "$WORK_DIR/filebrowser.db",
  "root": "$WORK_DIR"
}
EOF
        filebrowser config init --config /tmp/filebrowser.json
        filebrowser users add "${FB_USERNAME:-admin}" "${FB_PASSWORD:-admin}" --config /tmp/filebrowser.json --perm.admin
        filebrowser --config /tmp/filebrowser.json &
        log "FileBrowser up."
    else
        log "FileBrowser disabled."
    fi
}

# Launch the main app
launch_app() {
    log "Launching ComfyUI..."
    if [[ -f "main.py" ]];       then python3 main.py --listen 0.0.0.0 --port 7860
    elif [[ -f "launch.py" ]];   then python3 launch.py --listen 0.0.0.0 --port 7860
    elif [[ -f "app.py" ]];      then python3 app.py --host 0.0.0.0 --port 7860
    elif [[ -f "server.js" ]];   then node server.js
    elif [[ -f "ComfyUI/main.py" ]]; then
        cd ComfyUI && python3 main.py --listen 0.0.0.0 --port 7860
    else
        error "No entry point found."
        ls -la "$WORK_DIR"
        exit 1
    fi
}

# Main
main() {
    log "=== RunPod ComfyUI Start ==="
    log "WORK_DIR=$WORK_DIR  USE_VOLUME=$USE_VOLUME  FILEBROWSER=$FILEBROWSER"
    log "HF token: $( [[ -n "$HUGGINGFACE_TOKEN" ]] && echo "set" || echo "not set")"
    log "DOWNLOAD_PULID=$DOWNLOAD_PULID  DOWNLOAD_FLUX_CONTROLNET=$DOWNLOAD_FLUX_CONTROLNET  DOWNLOAD_FLUX_KONTEXT=$DOWNLOAD_FLUX_KONTEXT"

    # GPU info
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits
        export PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:512
    fi

    # Kick off downloads in parallel
    download_civitai_models & CIV_P=$!
    download_flux_models   & HF_P=$!
    download_pulid_models  & PL_P=$!
    download_flux_controlnet & CN_P=$!
    download_flux_kontext  & KT_P=$!

    # Wait
    wait $CIV_P $HF_P $PL_P $CN_P $KT_P

    # FileBrowser + launch
    start_filebrowser
    sleep 2
    launch_app
}

main "$@"
