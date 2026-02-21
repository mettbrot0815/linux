#!/usr/bin/env bash

# Local LLM setup script for Ubuntu 24.04 – Ollama + Open WebUI
# Run with: sudo bash grok.sh   (or chmod +x grok.sh && sudo ./grok.sh)

set -euo pipefail

echo "============================================================="
echo "  Local LLM Setup – Ollama + Open WebUI (2025/2026 edition)  "
echo "============================================================="
echo
echo "This script will:"
echo "  • Update system"
echo "  • Detect CPU/RAM/GPU"
echo "  • Install Ollama"
echo "  • Pull 1–3 models that should actually run well on your hardware"
echo "  • Install Docker + Open WebUI (ChatGPT-like browser UI)"
echo
echo "Press Enter to continue or Ctrl+C to quit."
read -r

# 1. Update & upgrade
apt update -y && apt upgrade -y

# 2. Basic tools
apt install -y curl git python3 python3-pip python3-venv

# 3. Hardware detection
CPU_CORES=$(nproc)
TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
echo "→ CPU cores : $CPU_CORES"
echo "→ RAM       : ${TOTAL_RAM_GB} GB"

GPU_TYPE="cpu"
GPU_VRAM_MB=0

if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_TYPE="nvidia"
    GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1 | awk '{print int($1)}')
    echo "→ NVIDIA GPU detected – VRAM: ${GPU_VRAM_MB} MB"
elif lspci | grep -Ei 'vga|3d|display' | grep -i nvidia >/dev/null; then
    echo "NVIDIA card found but drivers missing → installing..."
    apt install -y ubuntu-drivers-common
    ubuntu-drivers autoinstall
    echo "→ Drivers installed. You should reboot later."
    GPU_TYPE="nvidia"
    GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | awk '{print int($1)}' || echo 0)
fi

# Very rough AMD/Intel GPU fallback (ROCm/ipex not auto-installed here)
if [ "$GPU_TYPE" = "cpu" ] && lspci | grep -Ei 'vga|3d|display' | grep -iE 'amd|radeon|intel' >/dev/null; then
    echo "→ AMD/Intel GPU detected (limited acceleration support)"
    GPU_TYPE="other-gpu"
fi

# 4. Install Ollama
echo "Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh

# Start ollama server in background (will keep running after script)
systemctl --user enable --now ollama || ollama serve &

sleep 6

# 5. Choose sensible models
echo
echo "Picking models that should run reasonably on your hardware:"

models=()

if [ "$GPU_TYPE" = "nvidia" ] && [ "$GPU_VRAM_MB" -ge 10000 ]; then
    models=("llama3.1:8b" "gemma2:9b" "mistral-nemo")
    echo "→ High VRAM → good 7–9B class models"
elif [ "$GPU_TYPE" = "nvidia" ] && [ "$GPU_VRAM_MB" -ge 6000 ]; then
    models=("llama3.1:8b" "phi3:medium" "gemma2:2b")
    echo "→ Mid-range GPU → 7–8B + small fast model"
elif [ "$GPU_TYPE" != "cpu" ] || [ "$TOTAL_RAM_GB" -ge 16 ]; then
    models=("llama3.2:3b" "phi3:mini" "gemma2:2b")
    echo "→ Decent CPU or low VRAM → 2–3B class models"
else
    models=("phi3:mini" "tinyllama" "gemma2:2b")
    echo "→ Low resources → smallest usable models"
fi

echo "→ Will download: ${models[*]}"
echo "Press Enter to pull models (can take 5–40 min depending on internet/model size)"
read -r

for m in "${models[@]}"; do
    echo "Pulling $m ..."
    ollama pull "$m"
done

# 6. Docker + Open WebUI
if ! command -v docker >/dev/null 2>&1; then
    echo "Installing Docker..."
    apt install -y docker.io
    systemctl enable --now docker
fi

echo "Launching Open WebUI..."
docker run -d -p 3000:8080 \
  --add-host=host.docker.internal:host-gateway \
  -v open-webui:/app/backend/data \
  --name open-webui \
  --restart unless-stopped \
  ghcr.io/open-webui/open-webui:main

echo
echo "============================================================="
echo "               Setup finished!"
echo "============================================================="
echo
echo "• CLI test:       ollama run ${models[0]}"
echo "• Web UI:         http://localhost:3000     (or your IP:3000)"
echo "                Open in browser → sign up → select model"
echo
echo "If you installed NVIDIA drivers, reboot now:"
echo "  sudo reboot"
echo
echo "Enjoy local AI! More models → https://ollama.com/library"