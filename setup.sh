#!/usr/bin/env bash
#
# setup.sh - Idempotent setup script for ExLlamaV2 + TabbyAPI + Open WebUI
#
# This script:
#   1. Creates a Python virtual environment
#   2. Clones/updates TabbyAPI (which includes ExLlamaV2)
#   3. Installs all dependencies
#   4. Downloads the specified EXL2 model
#
# Usage:
#   ./setup.sh                           Full setup with default model
#   ./setup.sh --skip-model              Setup without model download
#   ./setup.sh download-model REPO REV   Download additional model

set -euo pipefail

# ============================================================================
# Configuration (override via environment variables)
# ============================================================================

# Default model to download (small 3B model for testing)
MODEL_REPO="${MODEL_REPO:-bartowski/Llama-3.2-3B-Instruct-exl2}"
MODEL_REVISION="${MODEL_REVISION:-6_5}"

# Python version requirement
PYTHON_MIN_VERSION="3.10"

# ============================================================================
# Setup
# ============================================================================

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ============================================================================
# Download model function
# ============================================================================

download_model() {
    local repo="$1"
    local revision="$2"
    local models_dir="${SCRIPT_DIR}/models"

    mkdir -p "$models_dir"

    # Derive local model name from repo
    local model_name
    model_name=$(echo "$repo" | sed 's/.*\///')
    local model_local_dir="${models_dir}/${model_name}_${revision}"

    if [ -d "$model_local_dir" ] && [ -f "${model_local_dir}/config.json" ]; then
        log_ok "Model already downloaded at ${model_local_dir}"
        return 0
    fi

    log_info "Downloading model: ${repo} (revision: ${revision})"
    log_info "Target directory: ${model_local_dir}"
    log_info "This may take a while for large models..."

    # Activate venv if not already active
    if [ -z "${VIRTUAL_ENV:-}" ] && [ -d "${SCRIPT_DIR}/venv" ]; then
        source "${SCRIPT_DIR}/venv/bin/activate"
    fi

    # Use huggingface-cli for resumable downloads
    huggingface-cli download \
        "$repo" \
        --revision "$revision" \
        --local-dir "$model_local_dir" \
        --local-dir-use-symlinks False

    log_ok "Model downloaded successfully to ${model_local_dir}"
}

# ============================================================================
# Parse arguments
# ============================================================================

SKIP_MODEL=false
DOWNLOAD_ONLY=false

# Handle download-model subcommand
if [ "${1:-}" = "download-model" ]; then
    if [ $# -lt 3 ]; then
        log_error "Usage: $0 download-model <repo> <revision>"
        log_error "Example: $0 download-model bartowski/Llama-3.3-70B-Instruct-exl2 4_25"
        exit 1
    fi
    DOWNLOAD_ONLY=true
    MODEL_REPO="$2"
    MODEL_REVISION="$3"
fi

for arg in "$@"; do
    case $arg in
        --skip-model)
            SKIP_MODEL=true
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "       $0 download-model <repo> <revision>"
            echo ""
            echo "Commands:"
            echo "  download-model  Download an additional model"
            echo ""
            echo "Options:"
            echo "  --skip-model    Skip model download during setup"
            echo "  --help, -h      Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                                              # Full setup with default 3B model"
            echo "  $0 --skip-model                                 # Setup without downloading models"
            echo "  $0 download-model bartowski/QwQ-32B-exl2 6_5    # Download QwQ 32B model"
            echo ""
            echo "Environment variables:"
            echo "  MODEL_REPO      HuggingFace model repo (default: bartowski/Llama-3.2-3B-Instruct-exl2)"
            echo "  MODEL_REVISION  Model revision/branch (default: 6_5)"
            exit 0
            ;;
        download-model)
            # Already handled above
            ;;
    esac
done

# If download-only mode, just download and exit
if [ "$DOWNLOAD_ONLY" = true ]; then
    download_model "$MODEL_REPO" "$MODEL_REVISION"
    exit 0
fi

# ============================================================================
# Pre-flight checks
# ============================================================================

log_info "Running pre-flight checks..."

# Check for Python
if ! command -v python3 &> /dev/null; then
    log_error "Python 3 is not installed. Please install Python ${PYTHON_MIN_VERSION}+"
    exit 1
fi

# Check Python version
PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
if ! python3 -c "import sys; exit(0 if sys.version_info >= (3, 10) else 1)"; then
    log_error "Python ${PYTHON_MIN_VERSION}+ required, found ${PYTHON_VERSION}"
    exit 1
fi
log_ok "Python ${PYTHON_VERSION} found"

# Check for git
if ! command -v git &> /dev/null; then
    log_error "Git is not installed"
    exit 1
fi
log_ok "Git found"

# Check for NVIDIA GPU and CUDA
if ! command -v nvidia-smi &> /dev/null; then
    log_error "nvidia-smi not found. NVIDIA drivers required."
    exit 1
fi

GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader | head -1)
log_ok "Found ${GPU_COUNT} NVIDIA GPU(s)"

# Show GPU info
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | while read -r line; do
    log_info "  GPU: $line"
done

# Check CUDA version
if command -v nvcc &> /dev/null; then
    CUDA_VERSION=$(nvcc --version | grep "release" | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p')
    log_ok "CUDA ${CUDA_VERSION} found"
else
    log_warn "nvcc not found - CUDA toolkit may not be in PATH"
    log_warn "ExLlamaV2 installation may need CUDA toolkit"
fi

# ============================================================================
# Create/update virtual environment
# ============================================================================

VENV_DIR="${SCRIPT_DIR}/venv"

if [ ! -d "$VENV_DIR" ]; then
    log_info "Creating Python virtual environment..."
    python3 -m venv "$VENV_DIR"
    log_ok "Virtual environment created at ${VENV_DIR}"
else
    log_ok "Virtual environment already exists"
fi

# Activate venv
source "${VENV_DIR}/bin/activate"

# Upgrade pip
log_info "Upgrading pip..."
pip install --upgrade pip wheel setuptools > /dev/null

# ============================================================================
# Clone/update TabbyAPI
# ============================================================================

TABBY_DIR="${SCRIPT_DIR}/tabbyapi"

if [ ! -d "$TABBY_DIR" ]; then
    log_info "Cloning TabbyAPI..."
    git clone https://github.com/theroyallab/tabbyAPI.git "$TABBY_DIR"
    log_ok "TabbyAPI cloned"
else
    log_info "Updating TabbyAPI..."
    cd "$TABBY_DIR"
    git fetch origin
    # Get the default branch
    DEFAULT_BRANCH=$(git remote show origin | grep "HEAD branch" | sed 's/.*: //')
    git checkout "$DEFAULT_BRANCH"
    git pull origin "$DEFAULT_BRANCH"
    cd "$SCRIPT_DIR"
    log_ok "TabbyAPI updated"
fi

# ============================================================================
# Install dependencies
# ============================================================================

log_info "Installing TabbyAPI dependencies..."
cd "$TABBY_DIR"

# Install TabbyAPI requirements
if [ -f "requirements.txt" ]; then
    pip install -r requirements.txt
fi

# Install with CUDA support - TabbyAPI uses pyproject.toml
# Install the cu121 extras for CUDA 12.x support
log_info "Installing TabbyAPI with CUDA 12.x support..."
pip install .[cu121]

cd "$SCRIPT_DIR"
log_ok "Dependencies installed"

# Install huggingface_hub CLI for model downloads
log_info "Ensuring huggingface-cli is available..."
pip install --upgrade huggingface_hub[cli] > /dev/null
log_ok "huggingface-cli ready"

# ============================================================================
# Download model
# ============================================================================

if [ "$SKIP_MODEL" = true ]; then
    log_warn "Skipping model download (--skip-model specified)"
else
    download_model "$MODEL_REPO" "$MODEL_REVISION"
fi

# For summary below
MODELS_DIR="${SCRIPT_DIR}/models"
MODEL_NAME=$(echo "$MODEL_REPO" | sed 's/.*\///')
MODEL_LOCAL_DIR="${MODELS_DIR}/${MODEL_NAME}_${MODEL_REVISION}"

# ============================================================================
# Create default config if it doesn't exist
# ============================================================================

if [ ! -f "${SCRIPT_DIR}/tabby_config.yml" ]; then
    log_warn "tabby_config.yml not found - please create it"
else
    log_ok "tabby_config.yml found"
fi

# ============================================================================
# Pull Open WebUI Docker image
# ============================================================================

if command -v docker &> /dev/null; then
    log_info "Pulling Open WebUI Docker image..."
    docker pull ghcr.io/open-webui/open-webui:main
    log_ok "Open WebUI image ready"
else
    log_warn "Docker not found - skipping Open WebUI image pull"
    log_warn "Install Docker to use Open WebUI"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "============================================================================"
log_ok "Setup complete!"
echo "============================================================================"
echo ""
echo "Installed components:"
echo "  - Python venv:  ${VENV_DIR}"
echo "  - TabbyAPI:     ${TABBY_DIR}"
echo "  - Models:       ${MODELS_DIR}"
echo ""
if [ -d "$MODEL_LOCAL_DIR" ]; then
    echo "Downloaded model:"
    echo "  - ${MODEL_LOCAL_DIR}"
    echo ""
fi
echo "Next steps:"
echo "  1. Review/edit tabby_config.yml if needed"
echo "  2. Run ./start.sh to start all services"
echo "  3. Open http://localhost:3000 in your browser"
echo ""
