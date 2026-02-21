#!/usr/bin/env bash
# simple-local-llm.sh – Local LLM setup (Ollama + Open WebUI + extras)
# Run with: bash simple-local-llm.sh

set -euo pipefail
trap 'echo -e "\n\033[1;31m❌ Error on line $LINENO\033[0m"' ERR

# Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

echo -e "${BLUE}=============================================================${NC}"
echo -e "${BLUE}         Simple Local LLM Setup – Ollama + Web UI           ${NC}"
echo -e "${BLUE}=============================================================${NC}"
echo ""
echo "This script will:"
echo "  • Update system packages"
echo "  • Detect your hardware and suggest suitable models"
echo "  • Install Ollama (local LLM runner)"
echo "  • Pull 1–3 models that should run well on your system"
echo "  • Optionally install llama.cpp for GGUF model support"
echo "  • Optionally add helpful aliases to your shell"
echo "  • Install Docker and run Open WebUI (browser interface)"
echo ""
echo -e "${YELLOW}Press Enter to continue or Ctrl+C to quit.${NC}"
read -r

# ----------------------------------------------------------------------
# 1. System update and basic tools
# ----------------------------------------------------------------------
echo -e "\n${BLUE}🔧 Updating system and installing prerequisites...${NC}"
apt update -y && apt upgrade -y
apt install -y curl git python3 python3-pip python3-venv lspci

# ----------------------------------------------------------------------
# 2. Hardware detection (for model suggestions)
# ----------------------------------------------------------------------
CPU_CORES=$(nproc)
TOTAL_RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
echo -e "\n${CYAN}→ CPU cores : $CPU_CORES${NC}"
echo -e "${CYAN}→ RAM       : ${TOTAL_RAM_GB} GB${NC}"

GPU_TYPE="cpu"
GPU_VRAM_MB=0

if command -v nvidia-smi &>/dev/null; then
    GPU_TYPE="nvidia"
    GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n1 | awk '{print int($1)}')
    echo -e "${CYAN}→ NVIDIA GPU detected – VRAM: ${GPU_VRAM_MB} MB${NC}"
elif lspci | grep -Ei 'vga|3d|display' | grep -i nvidia &>/dev/null; then
    echo -e "${YELLOW}⚠️  NVIDIA card found but drivers missing. Installing...${NC}"
    apt install -y ubuntu-drivers-common
    ubuntu-drivers autoinstall
    echo -e "${YELLOW}Drivers installed. A reboot may be needed later.${NC}"
    GPU_TYPE="nvidia"
    # We can't get VRAM until after reboot, so assume at least 4GB for model selection
    GPU_VRAM_MB=4096
fi

# ----------------------------------------------------------------------
# 3. Choose models based on hardware
# ----------------------------------------------------------------------
echo ""
echo -e "${BLUE}📦 Selecting models that should run reasonably on your hardware...${NC}"

models=()

if [ "$GPU_TYPE" = "nvidia" ] && [ "$GPU_VRAM_MB" -ge 10000 ]; then
    models=("llama3.1:8b" "gemma2:9b" "mistral-nemo")
    echo -e "  → High VRAM → 7–9B class models"
elif [ "$GPU_TYPE" = "nvidia" ] && [ "$GPU_VRAM_MB" -ge 6000 ]; then
    models=("llama3.1:8b" "phi3:medium" "gemma2:2b")
    echo -e "  → Mid‑range GPU → 7–8B + small fast model"
elif [ "$GPU_TYPE" != "cpu" ] || [ "$TOTAL_RAM_GB" -ge 16 ]; then
    models=("llama3.2:3b" "phi3:mini" "gemma2:2b")
    echo -e "  → Decent CPU or low VRAM → 2–3B class models"
else
    models=("phi3:mini" "tinyllama" "gemma2:2b")
    echo -e "  → Low resources → smallest usable models"
fi

echo -e "${YELLOW}Will download: ${models[*]}${NC}"
echo -e "${YELLOW}Press Enter to continue or Ctrl+C to abort.${NC}"
read -r

# ----------------------------------------------------------------------
# 4. Install / upgrade Ollama
# ----------------------------------------------------------------------
echo -e "\n${BLUE}🦙 Installing Ollama...${NC}"
if command -v ollama &>/dev/null; then
    echo -e "${YELLOW}Ollama already installed. Re-run installer to upgrade? (y/n)${NC}"
    read -r upgrade_ollama
    if [[ "$upgrade_ollama" =~ ^[Yy]$ ]]; then
        curl -fsSL https://ollama.com/install.sh | sh
    else
        echo -e "${GREEN}Keeping existing Ollama.${NC}"
    fi
else
    curl -fsSL https://ollama.com/install.sh | sh
fi

# Start Ollama service (will keep running after script)
systemctl start ollama 2>/dev/null || ollama serve &>/dev/null &
sleep 5

# Pull models
echo -e "\n${BLUE}⬇️  Pulling models (this may take a while depending on model size and internet)...${NC}"
for m in "${models[@]}"; do
    echo -e "${CYAN}Pulling $m ...${NC}"
    ollama pull "$m"
done

# ----------------------------------------------------------------------
# 5. Optional: Install llama.cpp for GGUF support
# ----------------------------------------------------------------------
echo ""
echo -e "${BLUE}🔧 Do you want to install llama.cpp (for running raw GGUF models)? (y/n)${NC}"
read -r install_llamacpp
if [[ "$install_llamacpp" =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}Building llama.cpp from source...${NC}"
    apt install -y build-essential cmake
    cd /tmp
    git clone https://github.com/ggerganov/llama.cpp.git
    cd llama.cpp
    make -j$(nproc)
    mkdir -p "$HOME/.local/bin"
    cp main server "$HOME/.local/bin/" 2>/dev/null || true
    ln -sf "$HOME/.local/bin/main" "$HOME/.local/bin/llama-run" 2>/dev/null || true
    cd ~
    rm -rf /tmp/llama.cpp
    echo -e "${GREEN}llama.cpp installed. Use ~/.local/bin/llama-run to run GGUF models.${NC}"
fi

# ----------------------------------------------------------------------
# 6. Optional: Set up helpful aliases
# ----------------------------------------------------------------------
echo ""
echo -e "${BLUE}📝 Do you want to add useful aliases to your shell (e.g., 'ask', 'ollama-list', 'models-info')? (y/n)${NC}"
read -r add_aliases
if [[ "$add_aliases" =~ ^[Yy]$ ]]; then
    cat >> "$HOME/.bash_aliases" << 'EOF'
# ---------- Local LLM Aliases ----------
alias ollama-list='ollama list'
alias ollama-ps='ollama ps'
alias ollama-pull='ollama pull'
alias ollama-run='ollama run'
alias ollama-stop='ollama stop -a'
alias run-llama='ollama run llama3.2'
alias run-mistral='ollama run mistral'
alias run-codellama='ollama run codellama'
alias run-phi='ollama run phi3'
alias models-info='echo "Ollama models:" && ollama list && echo "" && echo "GGUF models:" && ls -lh ~/local-llm-models/gguf/*.gguf 2>/dev/null || echo "None"'
alias ask='ollama run llama3.2'
alias ask-fast='ollama run phi3'
alias ask-code='ollama run codellama'
alias llm-help='echo "Available: ask, ask-fast, ask-code, ollama-{list,ps,pull,run,stop}, run-{llama,mistral,codellama,phi}, models-info"'
# ---------------------------------------
EOF
    echo -e "${GREEN}Aliases added to ~/.bash_aliases. They will be available in new terminals.${NC}"
fi

# ----------------------------------------------------------------------
# 7. Install Docker and run Open WebUI
# ----------------------------------------------------------------------
echo ""
echo -e "${BLUE}🐳 Do you want to install Docker and run Open WebUI (ChatGPT-like browser UI)? (y/n)${NC}"
read -r install_docker
if [[ "$install_docker" =~ ^[Yy]$ ]]; then
    if ! command -v docker &>/dev/null; then
        echo -e "${CYAN}Installing Docker...${NC}"
        apt install -y docker.io
        systemctl enable --now docker
    else
        echo -e "${GREEN}Docker already installed.${NC}"
    fi

    echo -e "${CYAN}Launching Open WebUI container...${NC}"
    docker run -d -p 3000:8080 \
        --add-host=host.docker.internal:host-gateway \
        -v open-webui:/app/backend/data \
        --name open-webui \
        --restart unless-stopped \
        ghcr.io/open-webui/open-webui:main

    echo -e "${GREEN}Open WebUI started on http://localhost:3000${NC}"
fi

# ----------------------------------------------------------------------
# 8. Summary
# ----------------------------------------------------------------------
echo ""
echo -e "${GREEN}=============================================================${NC}"
echo -e "${GREEN}                Setup complete!                              ${NC}"
echo -e "${GREEN}=============================================================${NC}"
echo ""
echo -e "${CYAN}• Test a model from terminal:${NC}"
echo "    ollama run ${models[0]}"
if [ "$add_aliases" = "y" ]; then
    echo "    ask 'Hello, who are you?'"
fi
echo ""
if [ "$install_docker" = "y" ]; then
    echo -e "${CYAN}• Open WebUI:${NC}"
    echo "    http://localhost:3000"
    echo "    (Create an account – first user becomes admin)"
    echo ""
fi
if [ "$install_llamacpp" = "y" ]; then
    echo -e "${CYAN}• For GGUF models:${NC}"
    echo "    mkdir -p ~/local-llm-models/gguf"
    echo "    # Place .gguf files there, then run:"
    echo "    ~/.local/bin/llama-run -m ~/local-llm-models/gguf/your-model.gguf -p 'Hello'"
    echo ""
fi
if [ "$add_aliases" = "y" ]; then
    echo -e "${CYAN}• Aliases available in new terminals:${NC}"
    echo "    llm-help  – show quick reference"
    echo "    ask, ask-fast, ask-code, models-info, etc."
    echo ""
fi
echo -e "${YELLOW}If NVIDIA drivers were installed, reboot to use GPU acceleration.${NC}"
echo -e "${GREEN}Enjoy your local LLMs!${NC}"