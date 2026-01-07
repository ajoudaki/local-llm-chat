#!/usr/bin/env bash
#
# start.sh - Start TabbyAPI and Open WebUI services
#
# TabbyAPI runs natively (for GPU access), Open WebUI runs in Docker.
# TabbyAPI starts first and must be healthy before Open WebUI connects.
#
# Usage: ./start.sh [--no-webui]
#   --no-webui  Only start TabbyAPI, skip Open WebUI

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

TABBY_PORT="${TABBY_PORT:-5000}"
WEBUI_PORT="${WEBUI_PORT:-3000}"
TABBY_STARTUP_TIMEOUT="${TABBY_STARTUP_TIMEOUT:-300}"  # 5 minutes for model loading

# ============================================================================
# Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Parse arguments
START_WEBUI=true
for arg in "$@"; do
    case $arg in
        --no-webui)
            START_WEBUI=false
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--no-webui]"
            echo ""
            echo "Options:"
            echo "  --no-webui  Only start TabbyAPI, skip Open WebUI"
            echo ""
            echo "Environment variables:"
            echo "  TABBY_PORT    TabbyAPI port (default: 5000)"
            echo "  WEBUI_PORT    Open WebUI port (default: 3000)"
            exit 0
            ;;
    esac
done

# ============================================================================
# Pre-flight checks
# ============================================================================

# Check if venv exists
if [ ! -d "${SCRIPT_DIR}/venv" ]; then
    log_error "Virtual environment not found. Run ./setup.sh first."
    exit 1
fi

# Check if TabbyAPI is cloned
if [ ! -d "${SCRIPT_DIR}/tabbyapi" ]; then
    log_error "TabbyAPI not found. Run ./setup.sh first."
    exit 1
fi

# Check if already running
if [ -f "${SCRIPT_DIR}/logs/tabby.pid" ]; then
    OLD_PID=$(cat "${SCRIPT_DIR}/logs/tabby.pid")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        log_warn "TabbyAPI already running (PID: ${OLD_PID})"
        log_warn "Run ./stop.sh first or use the existing instance"
        exit 1
    else
        rm -f "${SCRIPT_DIR}/logs/tabby.pid"
    fi
fi

# ============================================================================
# Start TabbyAPI
# ============================================================================

log_info "Starting TabbyAPI on port ${TABBY_PORT}..."

# Activate virtual environment
source "${SCRIPT_DIR}/venv/bin/activate"

# Create logs directory
mkdir -p "${SCRIPT_DIR}/logs"

# Start TabbyAPI in background
cd "${SCRIPT_DIR}/tabbyapi"

# TabbyAPI uses main.py or start.py depending on version
if [ -f "main.py" ]; then
    TABBY_ENTRY="main.py"
elif [ -f "start.py" ]; then
    TABBY_ENTRY="start.py"
else
    # Try module-based launch
    TABBY_ENTRY="-m tabbyAPI.main"
fi

# Fix conda libstdc++ conflict - force system libstdc++
# The venv Python links to conda, which has an old libstdc++
# LD_PRELOAD forces loading the system version first
export LD_PRELOAD="/usr/lib/x86_64-linux-gnu/libstdc++.so.6"

# Launch TabbyAPI with our config
nohup python "$TABBY_ENTRY" \
    --config "${SCRIPT_DIR}/tabby_config.yml" \
    > "${SCRIPT_DIR}/logs/tabby.log" 2>&1 &

TABBY_PID=$!
echo "$TABBY_PID" > "${SCRIPT_DIR}/logs/tabby.pid"

log_info "TabbyAPI starting (PID: ${TABBY_PID})"
log_info "Log file: ${SCRIPT_DIR}/logs/tabby.log"

# Wait for TabbyAPI to be ready
log_info "Waiting for TabbyAPI to load model (this may take a few minutes)..."

SECONDS_WAITED=0
while [ $SECONDS_WAITED -lt $TABBY_STARTUP_TIMEOUT ]; do
    # Check if process is still running
    if ! kill -0 "$TABBY_PID" 2>/dev/null; then
        log_error "TabbyAPI exited unexpectedly. Check logs:"
        tail -50 "${SCRIPT_DIR}/logs/tabby.log"
        rm -f "${SCRIPT_DIR}/logs/tabby.pid"
        exit 1
    fi

    # Check if API is responding
    if curl -s "http://127.0.0.1:${TABBY_PORT}/health" > /dev/null 2>&1; then
        log_ok "TabbyAPI is ready!"
        break
    fi

    # Show progress
    if [ $((SECONDS_WAITED % 30)) -eq 0 ] && [ $SECONDS_WAITED -gt 0 ]; then
        log_info "Still loading... (${SECONDS_WAITED}s elapsed)"
        # Show last log line for progress
        tail -1 "${SCRIPT_DIR}/logs/tabby.log" 2>/dev/null || true
    fi

    sleep 5
    SECONDS_WAITED=$((SECONDS_WAITED + 5))
done

if [ $SECONDS_WAITED -ge $TABBY_STARTUP_TIMEOUT ]; then
    log_error "TabbyAPI failed to start within ${TABBY_STARTUP_TIMEOUT}s"
    log_error "Check logs: ${SCRIPT_DIR}/logs/tabby.log"
    exit 1
fi

cd "$SCRIPT_DIR"

# ============================================================================
# Start Open WebUI (Docker)
# ============================================================================

if [ "$START_WEBUI" = true ]; then
    if ! command -v docker &> /dev/null; then
        log_warn "Docker not found - skipping Open WebUI"
        log_warn "TabbyAPI is running at http://127.0.0.1:${TABBY_PORT}"
        exit 0
    fi

    log_info "Starting Open WebUI on port ${WEBUI_PORT}..."

    # Export variables for docker-compose
    export TABBY_PORT
    export WEBUI_PORT

    # Start Open WebUI (use docker-compose for v1 compatibility)
    docker-compose up -d

    # Wait for Open WebUI to be ready
    log_info "Waiting for Open WebUI to start..."
    WEBUI_WAITED=0
    while [ $WEBUI_WAITED -lt 60 ]; do
        if curl -s "http://127.0.0.1:${WEBUI_PORT}/health" > /dev/null 2>&1; then
            log_ok "Open WebUI is ready!"
            break
        fi
        sleep 2
        WEBUI_WAITED=$((WEBUI_WAITED + 2))
    done

    if [ $WEBUI_WAITED -ge 60 ]; then
        log_warn "Open WebUI may still be starting. Check: docker-compose logs -f"
    fi
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "============================================================================"
log_ok "Services started successfully!"
echo "============================================================================"
echo ""
echo "TabbyAPI (OpenAI-compatible API):"
echo "  - URL:     http://127.0.0.1:${TABBY_PORT}"
echo "  - Docs:    http://127.0.0.1:${TABBY_PORT}/docs"
echo "  - Logs:    ${SCRIPT_DIR}/logs/tabby.log"
echo "  - PID:     ${TABBY_PID}"
echo ""
if [ "$START_WEBUI" = true ]; then
    echo "Open WebUI (Chat Interface):"
    echo "  - URL:     http://localhost:${WEBUI_PORT}"
    echo "  - First visit: Create an admin account"
    echo ""
    echo "Additional Services (Docker):"
    echo "  - TTS:     http://localhost:8000  (OpenedAI Speech)"
    echo "  - STT:     http://localhost:8001  (Faster Whisper)"
    echo "  - Images:  http://localhost:8188  (ComfyUI)"
    echo ""
    echo "Configure audio/images in: Admin Panel → Settings → Audio/Images"
    echo ""
fi
echo "To stop services: ./stop.sh"
echo "To view TabbyAPI logs: tail -f ${SCRIPT_DIR}/logs/tabby.log"
echo "To view Docker logs: docker-compose logs -f"
echo ""
