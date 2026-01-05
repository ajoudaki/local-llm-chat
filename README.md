# Local LLM Chat Stack

Private, local LLM inference using ExLlamaV2 + TabbyAPI + Open WebUI.

Optimized for dual RTX 3090 (48GB total VRAM) running 70B-class models with tensor parallelism.

## Features

- **Fully Local**: All inference runs on your hardware, no external API calls
- **Privacy-First**: No telemetry, no prompt logging, no data collection
- **Multi-GPU**: Tensor parallelism across multiple GPUs for large models
- **Model Switching**: Switch between models directly from the Open WebUI dropdown
- **OpenAI-Compatible API**: Use with any OpenAI-compatible client

## Quick Start

```bash
# 1. Clone the repository
git clone <repo-url> local_chat
cd local_chat

# 2. Run setup (creates venv, installs deps, downloads default model)
./setup.sh

# 3. Start services
./start.sh

# 4. Open browser to http://localhost:3000
#    Create your admin account on first visit
```

## Requirements

### Hardware
- NVIDIA GPU(s) with CUDA support
- Recommended: 24GB+ VRAM for 70B models, 8GB+ for smaller models
- Tested with: 2x RTX 3090 (48GB total)

### Software
- Ubuntu 22.04/24.04 (or compatible Linux distro)
- NVIDIA drivers + CUDA 12.x toolkit
- Python 3.10+ (system Python, not conda)
- Docker and docker-compose
- ~50GB disk space for models

### Docker Setup

Ensure Docker is properly configured:

```bash
# Install Docker if not present
sudo apt install docker.io docker-compose

# Add your user to the docker group (log out and back in after)
sudo usermod -aG docker $USER

# Verify Docker works without sudo
docker ps
```

If `docker ps` requires sudo, you may need to:
1. Log out and log back in after adding yourself to the docker group
2. Or run `newgrp docker` in your current terminal

## Architecture

```
┌─────────────────────┐     ┌─────────────────────┐
│   Open WebUI        │────▶│     TabbyAPI        │
│   (Docker)          │     │  (Native Python)    │
│   Port 3000         │     │   Port 5000         │
└─────────────────────┘     └─────────────────────┘
                                    │
                           ┌────────┴────────┐
                           │   ExLlamaV2     │
                           │ Tensor Parallel │
                           └────────┬────────┘
                                    │
                           ┌────────┴────────┐
                           │  GPU(s)         │
                           │  (VRAM)         │
                           └─────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | Install dependencies and download model |
| `start.sh` | Start TabbyAPI + Open WebUI |
| `stop.sh` | Stop all services |
| `tabby_config.yml` | TabbyAPI configuration |
| `docker-compose.yml` | Open WebUI container config |

## Configuration

### Downloading Models

The default setup downloads a small 3B model for testing. To download additional models:

```bash
# Download Llama 3.1 8B (good for testing, fits on 8GB VRAM)
./setup.sh download-model bartowski/Meta-Llama-3.1-8B-Instruct-exl2 6_5

# Download QwQ 32B (fits on 24GB or 2x12GB)
./setup.sh download-model bartowski/QwQ-32B-exl2 6_5

# Download Llama 3.3 70B (requires 48GB, e.g., 2x24GB)
./setup.sh download-model bartowski/Llama-3.3-70B-Instruct-exl2 4_25
```

Note: Model revision (e.g., `6_5`, `4_25`) indicates bits-per-weight quantization.
Lower = smaller but less accurate. Check HuggingFace for available revisions.

### Changing the Default Model

Edit `tabby_config.yml`:

```yaml
model:
  model_name: Llama-3.3-70B-Instruct-exl2_4_25  # folder name in models/
```

Then restart: `./stop.sh && ./start.sh`

### Model Switching from UI

With `inline_model_loading: true` (default), you can switch models directly from
the Open WebUI dropdown menu. The model will be loaded/unloaded automatically.

### Memory Tuning

For different VRAM configurations, adjust `tabby_config.yml`:

```yaml
model:
  # Reduce context for less VRAM
  max_seq_len: 4096
  cache_size: 4096

  # Use Q4 cache for more VRAM savings (lower quality)
  cache_mode: Q4

  # Disable tensor parallelism for single GPU
  tensor_parallel: false
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TABBY_PORT` | 5000 | TabbyAPI port |
| `WEBUI_PORT` | 3000 | Open WebUI port |
| `MODEL_REPO` | bartowski/Llama-3.2-3B-Instruct-exl2 | Model to download |
| `MODEL_REVISION` | 6_5 | Model quantization branch |

## Privacy & Security

This stack is designed for fully local, private inference:

- **No telemetry**: All analytics disabled in Open WebUI
- **No prompt logging**: TabbyAPI configured to not log prompts
- **No external calls**: Models run entirely locally

### Firewall Recommendations

TabbyAPI binds to `0.0.0.0` to allow Docker container access.
Block external access to prevent accidental exposure:

```bash
# UFW (Ubuntu) - block external access to API ports
sudo ufw deny in on eth0 to any port 5000  # TabbyAPI
sudo ufw deny in on eth0 to any port 3000  # Open WebUI

# Or allow only from local network
sudo ufw allow from 192.168.0.0/16 to any port 3000
sudo ufw allow from 192.168.0.0/16 to any port 5000
```

### After First Login

Disable public signup by setting in docker-compose.yml:

```yaml
environment:
  - ENABLE_SIGNUP=False
```

Then restart: `docker-compose down && docker-compose up -d`

## Troubleshooting

### TabbyAPI won't start

Check logs:
```bash
tail -f logs/tabby.log
```

Common issues:
- **CUDA out of memory**: Reduce `max_seq_len` or use smaller model
- **Model not found**: Check `model_name` in `tabby_config.yml` matches folder in `models/`
- **GLIBCXX errors**: The start script includes a fix, but ensure you're not using conda Python

### Open WebUI shows empty model list

1. Check TabbyAPI is running: `curl http://localhost:5000/v1/models`
2. Check the API returns models with correct names
3. Ensure `inline_model_loading: true` is set in `tabby_config.yml`

### Open WebUI can't connect to TabbyAPI

Ensure TabbyAPI is running:
```bash
curl http://localhost:5000/health
```

Check Docker can reach host:
```bash
docker exec open-webui curl http://172.17.0.1:5000/health
```

### Slow inference

- Ensure tensor parallelism is enabled (`tensor_parallel: true`) for multi-GPU
- Check all GPUs are being used: `watch nvidia-smi`
- Reduce context length if memory pressure is high

### Model switching doesn't work

Ensure `inline_model_loading: true` is set in `tabby_config.yml` and restart TabbyAPI.

## API Usage

TabbyAPI provides an OpenAI-compatible API:

```bash
# List available models
curl http://localhost:5000/v1/models

# Chat completion
curl http://localhost:5000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Llama-3.3-70B-Instruct-exl2_4_25",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# Load a different model
curl -X POST http://localhost:5000/v1/model/load \
  -H "Content-Type: application/json" \
  -d '{"name": "Meta-Llama-3.1-8B-Instruct-exl2_6_5"}'
```

API documentation: http://localhost:5000/docs

## Recommended Models

| Model | VRAM Required | Use Case |
|-------|---------------|----------|
| Llama-3.2-3B | ~4GB | Testing, quick responses |
| Llama-3.1-8B | ~8GB | General use, good quality |
| QwQ-32B | ~24GB | Reasoning, complex tasks |
| Llama-3.3-70B | ~40GB | Best quality, requires multi-GPU |

## License

This setup configuration is provided as-is. See individual project licenses:
- [ExLlamaV2](https://github.com/turboderp/exllamav2) - MIT
- [TabbyAPI](https://github.com/theroyallab/tabbyAPI) - AGPL-3.0
- [Open WebUI](https://github.com/open-webui/open-webui) - MIT
