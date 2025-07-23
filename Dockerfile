FROM nvidia/cuda:12.1.1-devel-ubuntu22.04

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV TORCH_CUDA_ARCH_LIST="8.9;9.0"
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=${CUDA_HOME}/bin:${PATH}
ENV LD_LIBRARY_PATH=${CUDA_HOME}/lib64:${LD_LIBRARY_PATH}

# Set working directory
WORKDIR /workspace

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-dev \
    python3-venv \
    git \
    wget \
    curl \
    unzip \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgomp1 \
    libgoogle-perftools4 \
    libtcmalloc-minimal4 \
    build-essential \
    cmake \
    ninja-build \
    pkg-config \
    libopencv-dev \
    libavcodec-dev \
    libavformat-dev \
    libswscale-dev \
    libjpeg-dev \
    libpng-dev \
    libtiff-dev \
    libwebp-dev \
    libopenjp2-7-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Update pip and install essential Python packages
RUN python3 -m pip install --upgrade pip setuptools wheel

# Install PyTorch with CUDA support
RUN pip install torch==2.1.2 torchvision==0.16.2 torchaudio==2.1.2 --index-url https://download.pytorch.org/whl/cu121

# Install xformers without dependencies to avoid conflicts
RUN pip install xformers==0.0.23.post1 --no-deps

# Install FileBrowser
RUN curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash

# Copy the repository contents
COPY . /workspace/

# Initialize and update git submodules
RUN git submodule update --init --recursive

# Install ComfyUI dependencies
RUN cd /workspace/external/hearmeman && \
    if [ -f requirements.txt ]; then pip install -r requirements.txt; fi && \
    if [ -f ComfyUI/requirements.txt ]; then pip install -r ComfyUI/requirements.txt; fi

# Install additional Python dependencies commonly needed for ComfyUI
RUN pip install \
    opencv-python-headless \
    pillow \
    numpy \
    scipy \
    matplotlib \
    requests \
    tqdm \
    safetensors \
    transformers \
    diffusers \
    accelerate \
    compel \
    controlnet-aux \
    clip-interrogator \
    insightface \
    onnxruntime-gpu \
    segment-anything \
    groundingdino-py \
    addict \
    yapf \
    timm \
    fvcore \
    omegaconf

# Install CivitAI downloader dependencies
RUN pip install civitai-downloader

# Create necessary directories
RUN mkdir -p /workspace/models/checkpoints \
    /workspace/models/loras \
    /workspace/models/vae \
    /workspace/input \
    /workspace/output \
    /workspace/logs \
    /runpod-volume/models/checkpoints \
    /runpod-volume/models/loras \
    /runpod-volume/models/vae \
    /runpod-volume/input \
    /runpod-volume/output \
    /runpod-volume/logs

# Set proper permissions
RUN chmod -R 755 /workspace /runpod-volume

# Copy and set permissions for start script
COPY start.sh /workspace/start.sh
RUN chmod +x /workspace/start.sh

# Expose ports
EXPOSE 7860 8080 3000

# Set environment variables with defaults
ENV USE_VOLUME=false
ENV FILEBROWSER=false
ENV FILEBROWSER_PASSWORD=admin
ENV CIVITAI_TOKEN=""
ENV CHECKPOINT_IDS_TO_DOWNLOAD=""
ENV LORA_IDS_TO_DOWNLOAD=""
ENV VAE_IDS_TO_DOWNLOAD=""

# Use start.sh as entrypoint
ENTRYPOINT ["/workspace/start.sh"]
