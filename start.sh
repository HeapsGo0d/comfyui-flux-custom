#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
}

# Trap function for clean exit
exit_clean() {
    log "Received termination signal. Cleaning up..."
    
    # Kill background processes
    jobs -p | xargs -r kill
    
    # Clean logs and cache
    if [[ "$USE_VOLUME" == "true" ]]; then
        WORK_DIR="/runpod-volume"
    else
        WORK_DIR="/workspace"
    fi
    
    # Clean temporary files
    find "$WORK_DIR" -name "*.tmp" -delete 2>/dev/null || true
    find "$WORK_DIR" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    
    # Clean logs older than 7 days
    find "$WORK_DIR/logs" -name "*.log" -mtime +7 -delete 2>/dev/null || true
    
    log "Cleanup completed. Exiting..."
    exit 0
}

# Set trap for clean exit
trap exit_clean SIGINT SIGTERM EXIT

# Determine working directory
if [[ "$USE_VOLUME" == "true" ]]; then
    WORK_DIR="/runpod-volume"
    log "Using persistent volume: $WORK_DIR"
    
    # Create necessary directories in volume
    mkdir -p "$WORK_DIR"/{models/{checkpoints,loras,vae},input,output,logs}
    
    # Copy ComfyUI to volume if not exists
    if [[ ! -d "$WORK_DIR/ComfyUI" ]]; then
        log "Copying ComfyUI to volume..."
        cp -r /workspace/external/hearmeman/* "$WORK_DIR/"
    fi
    
    cd "$WORK_DIR"
else
    WORK_DIR="/workspace/external/hearmeman"
    log "Using container workspace: $WORK_DIR"
    cd "$WORK_DIR"
fi

# Function to download models from CivitAI
download_civitai_models() {
    if [[ -z "$CIVITAI_TOKEN" ]]; then
        warn "CIVITAI_TOKEN not set. Skipping CivitAI downloads."
        return
    fi
    
    log "Starting CivitAI model downloads..."
    
    # Download checkpoints
    if [[ -n "$CHECKPOINT_IDS_TO_DOWNLOAD" ]]; then
        log "Downloading checkpoints..."
        IFS=',' read -ra CHECKPOINT_IDS <<< "$CHECKPOINT_IDS_TO_DOWNLOAD"
        for id in "${CHECKPOINT_IDS[@]}"; do
            id=$(echo "$id" | xargs) # trim whitespace
            if [[ -n "$id" ]]; then
                log "Downloading checkpoint ID: $id"
                civitai-downloader --token "$CIVITAI_TOKEN" --model-id "$id" --output-dir "$WORK_DIR/models/checkpoints" || warn "Failed to download checkpoint $id"
            fi
        done
    fi
    
    # Download LoRAs
    if [[ -n "$LORA_IDS_TO_DOWNLOAD" ]]; then
        log "Downloading LoRAs..."
        IFS=',' read -ra LORA_IDS <<< "$LORA_IDS_TO_DOWNLOAD"
        for id in "${LORA_IDS[@]}"; do
            id=$(echo "$id" | xargs) # trim whitespace
            if [[ -n "$id" ]]; then
                log "Downloading LoRA ID: $id"
                civitai-downloader --token "$CIVITAI_TOKEN" --model-id "$id" --output-dir "$WORK_DIR/models/loras" || warn "Failed to download LoRA $id"
            fi
        done
    fi
    
    # Download VAEs
    if [[ -n "$VAE_IDS_TO_DOWNLOAD" ]]; then
        log "Downloading VAEs..."
        IFS=',' read -ra VAE_IDS <<< "$VAE_IDS_TO_DOWNLOAD"
        for id in "${VAE_IDS[@]}"; do
            id=$(echo "$id" | xargs) # trim whitespace
            if [[ -n "$id" ]]; then
                log "Downloading VAE ID: $id"
                civitai-downloader --token "$CIVITAI_TOKEN" --model-id "$id" --output-dir "$WORK_DIR/models/vae" || warn "Failed to download VAE $id"
            fi
        done
    fi
    
    log "CivitAI downloads completed."
}

# Function to start FileBrowser
start_filebrowser() {
    if [[ "$FILEBROWSER" == "true" ]]; then
        log "Starting FileBrowser on port 8080..."
        
        # Configure FileBrowser
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
        
        # Start FileBrowser in background
        filebrowser config init --config /tmp/filebrowser.json
        filebrowser users add admin "$FILEBROWSER_PASSWORD" --config /tmp/filebrowser.json --perm.admin
        filebrowser --config /tmp/filebrowser.json &
        
        log "FileBrowser started successfully."
    else
        log "FileBrowser disabled."
    fi
}

# Function to find and launch the main application
launch_app() {
    log "Looking for main application file..."
    
    # Check for ComfyUI main.py first (most common)
    if [[ -f "main.py" ]]; then
        log "Found main.py, starting ComfyUI..."
        python3 main.py --listen 0.0.0.0 --port 7860
    elif [[ -f "launch.py" ]]; then
        log "Found launch.py, starting application..."
        python3 launch.py --listen 0.0.0.0 --port 7860
    elif [[ -f "app.py" ]]; then
        log "Found app.py, starting application..."
        python3 app.py --host 0.0.0.0 --port 7860
    elif [[ -f "server.js" ]]; then
        log "Found server.js, starting Node.js application..."
        # Check if node is installed
        if command -v node &> /dev/null; then
            node server.js
        else
            error "Node.js not found but server.js detected. Installing Node.js..."
            curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
            apt-get install -y nodejs
            node server.js
        fi
    elif [[ -f "ComfyUI/main.py" ]]; then
        log "Found ComfyUI/main.py, starting ComfyUI..."
        cd ComfyUI
        python3 main.py --listen 0.0.0.0 --port 7860
    else
        error "No recognized application entry point found (main.py, launch.py, app.py, server.js)"
        error "Available files in $WORK_DIR:"
        ls -la "$WORK_DIR"
        
        # Try to find Python files as fallback
        PYTHON_FILES=$(find "$WORK_DIR" -maxdepth 2 -name "*.py" -executable 2>/dev/null | head -5)
        if [[ -n "$PYTHON_FILES" ]]; then
            warn "Found these Python files that might be entry points:"
            echo "$PYTHON_FILES"
        fi
        
        exit 1
    fi
}

# Main execution
main() {
    log "=== RunPod ComfyUI Container Starting ==="
    log "Working directory: $WORK_DIR"
    log "USE_VOLUME: $USE_VOLUME"
    log "FILEBROWSER: $FILEBROWSER"
    
    # Set GPU memory allocation if available
    if command -v nvidia-smi &> /dev/null; then
        log "NVIDIA GPU detected:"
        nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits
        
        # Set memory fraction to prevent OOM
        export PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:512
    else
        warn "No NVIDIA GPU detected. Running in CPU mode."
    fi
    
    # Download CivitAI models
    download_civitai_models
    
    # Start FileBrowser if enabled
    start_filebrowser
    
    # Wait a moment for services to initialize
    sleep 2
    
    # Launch main application
    launch_app
}

# Run main function
main "$@"