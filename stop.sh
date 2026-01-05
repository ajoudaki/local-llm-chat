#!/usr/bin/env bash
#
# stop.sh - Gracefully stop all services
#
# Stops:
#   1. Open WebUI (Docker container)
#   2. TabbyAPI (native Python process)
#
# Usage: ./stop.sh [--force]
#   --force  Force kill if graceful shutdown fails

set -euo pipefail

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

FORCE_KILL=false
for arg in "$@"; do
    case $arg in
        --force|-f)
            FORCE_KILL=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--force]"
            echo ""
            echo "Options:"
            echo "  --force, -f  Force kill processes if graceful shutdown fails"
            exit 0
            ;;
    esac
done

# ============================================================================
# Stop Open WebUI (Docker)
# ============================================================================

log_info "Stopping Open WebUI..."

if command -v docker &> /dev/null; then
    if docker-compose ps --quiet 2>/dev/null | grep -q .; then
        docker-compose down
        log_ok "Open WebUI stopped"
    else
        log_info "Open WebUI container not running"
    fi
else
    log_info "Docker not available, skipping Open WebUI"
fi

# ============================================================================
# Stop TabbyAPI
# ============================================================================

log_info "Stopping TabbyAPI..."

PID_FILE="${SCRIPT_DIR}/logs/tabby.pid"
STOPPED=false

if [ -f "$PID_FILE" ]; then
    TABBY_PID=$(cat "$PID_FILE")

    if kill -0 "$TABBY_PID" 2>/dev/null; then
        log_info "Sending SIGTERM to TabbyAPI (PID: ${TABBY_PID})..."

        # Graceful shutdown with SIGTERM
        kill "$TABBY_PID"

        # Wait up to 30 seconds for graceful shutdown
        WAIT_COUNT=0
        while [ $WAIT_COUNT -lt 30 ]; do
            if ! kill -0 "$TABBY_PID" 2>/dev/null; then
                STOPPED=true
                break
            fi
            sleep 1
            WAIT_COUNT=$((WAIT_COUNT + 1))
        done

        if [ "$STOPPED" = false ]; then
            if [ "$FORCE_KILL" = true ]; then
                log_warn "Graceful shutdown timed out, force killing..."
                kill -9 "$TABBY_PID" 2>/dev/null || true
                STOPPED=true
            else
                log_warn "TabbyAPI did not stop gracefully within 30s"
                log_warn "Run with --force to force kill"
            fi
        fi

        if [ "$STOPPED" = true ]; then
            log_ok "TabbyAPI stopped"
        fi
    else
        log_info "TabbyAPI process not running (stale PID file)"
    fi

    rm -f "$PID_FILE"
else
    log_info "TabbyAPI PID file not found"

    # Try to find and kill any running TabbyAPI process
    FOUND_PIDS=$(pgrep -f "tabbyapi.*main.py\|tabbyAPI" 2>/dev/null || true)
    if [ -n "$FOUND_PIDS" ]; then
        log_warn "Found TabbyAPI process(es) without PID file: ${FOUND_PIDS}"
        if [ "$FORCE_KILL" = true ]; then
            echo "$FOUND_PIDS" | xargs kill -9 2>/dev/null || true
            log_ok "Killed orphan TabbyAPI process(es)"
        else
            log_warn "Use --force to kill these processes"
        fi
    fi
fi

# ============================================================================
# Cleanup
# ============================================================================

# Optionally clean up old log files (keep last few)
# Uncomment if desired:
# find "${SCRIPT_DIR}/logs" -name "*.log" -mtime +7 -delete 2>/dev/null || true

# ============================================================================
# Summary
# ============================================================================

echo ""
log_ok "All services stopped"
echo ""
