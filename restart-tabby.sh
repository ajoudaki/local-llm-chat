#!/bin/bash
# restart-tabby.sh - Clean restart of TabbyAPI

# Kill main process and tensor parallel workers
pkill -9 -f "python main.py.*tabby_config" 2>/dev/null
pkill -9 -f "exllamav3.*model_tp" 2>/dev/null

# Wait for GPU memory to be freed
echo "Waiting for GPU memory release..."
sleep 5

cd /home/amir/Codes/local_chat/tabbyapi
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libstdc++.so.6

/home/amir/Codes/local_chat/venv/bin/python main.py \
  --config /home/amir/Codes/local_chat/tabby_config.yml \
  >> /home/amir/Codes/local_chat/logs/tabbyapi.log 2>&1 &

echo "TabbyAPI starting..."
for i in {1..10}; do
  sleep 3
  if curl -s localhost:5000/health | grep -q healthy; then
    echo "Ready!"
    exit 0
  fi
  echo "  waiting... ($i)"
done
echo "Timeout - check logs: tail /home/amir/Codes/local_chat/logs/tabbyapi.log"
