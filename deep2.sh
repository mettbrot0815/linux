#!/usr/bin/env bash
set -euo pipefail

# ----- Configuration -------------------------------------------------
LOG_FILE="$HOME/local-llm-setup-$(date +%Y%m%d-%H%M%S).log"
VENV_DIR="$HOME/.local/share/llm-venv"
MODEL_BASE="$HOME/local-llm-models"
OLLAMA_MODELS="$MODEL_BASE/ollama"
GGUF_MODELS="$MODEL_BASE/gguf"
TEMP_DIR="$MODEL_BASE/temp"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/local-llm"
ALIAS_FILE="$HOME/.local_llm_aliases"

# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ----- Helper functions ----------------------------------------------
log() {
    echo -e "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

# Check if running under WSL2
is_wsl2() {
    if grep -qi microsoft /proc/version 2>/dev/null; then
        uname -r | grep -qi wsl2 && return 0 || return 1
    fi
    return 1
}

# Ask a yes/no question (default No)
ask_yes_no() {
    local prompt="$1 (y/N) "
    local answer
    read -p "$prompt" -n 1 -r answer
    echo
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ----- Pre-flight checks ---------------------------------------------
info "Starting local LLM setup..."

# Log all output
exec > >(tee -a "$LOG_FILE") 2>&1

# Check for sudo
if ! command -v sudo &> /dev/null; then
    error "sudo is required but not installed."
fi

# Update package list and install system dependencies
info "Installing core system dependencies..."
sudo apt update
sudo apt install -y curl wget git build-essential python3 python3-pip python3-venv

# Detect environment
if is_wsl2; then
    info "Running under WSL2 – using background process for Ollama."
    WSL2=true
else
    info "Running on native Linux – using systemd for Ollama."
    WSL2=false
fi

# ----- Directory setup -----------------------------------------------
info "Creating directory structure..."
mkdir -p "$OLLAMA_MODELS" "$GGUF_MODELS" "$TEMP_DIR" "$BIN_DIR" "$CONFIG_DIR"

# ----- Python virtual environment -------------------------------------
info "Setting up Python virtual environment at $VENV_DIR"
if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
fi
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"
pip install --upgrade pip setuptools wheel

# ----- Install llama-cpp-python (GGUF support) ----------------------
info "Installing llama-cpp-python with hardware acceleration detection..."

# Check for NVIDIA GPU and CUDA driver
if command -v nvidia-smi &> /dev/null; then
    CUDA_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | cut -d. -f1)
    if [[ -n "$CUDA_VERSION" && "$CUDA_VERSION" -ge 450 ]]; then
        info "NVIDIA GPU detected with driver version $CUDA_VERSION – installing CUDA-enabled llama-cpp-python"
        pip install llama-cpp-python \
            --index-url https://abetlen.github.io/llama-cpp-python/whl/cu121 \
            --extra-index-url https://pypi.org/simple || {
                warn "CUDA install failed, falling back to CPU version"
                pip install llama-cpp-python
            }
    else
        info "NVIDIA GPU driver too old or not detected – installing CPU version"
        pip install llama-cpp-python
    fi
else
    info "No NVIDIA GPU found – installing CPU version"
    pip install llama-cpp-python
fi

# ----- Install Ollama ------------------------------------------------
if ! command -v ollama &> /dev/null; then
    info "Installing Ollama via official script..."
    curl -fsSL https://ollama.com/install.sh | sh
else
    info "Ollama already installed, skipping."
fi

# ----- Configure Ollama ----------------------------------------------
info "Configuring Ollama..."

sudo mkdir -p /etc/ollama
sudo tee /etc/ollama/config.json > /dev/null <<'EOF'
{
    "disable_telemetry": true,
    "models": "$HOME/local-llm-models/ollama"
}
EOF

OLLAMA_ENV="OLLAMA_MODELS=$OLLAMA_MODELS OLLAMA_HOST=127.0.0.1:11434"

if [[ "$WSL2" == true ]]; then
    LAUNCHER="$BIN_DIR/ollama-start"
    info "Creating Ollama launcher at $LAUNCHER"
    cat > "$LAUNCHER" <<EOF
#!/bin/bash
export OLLAMA_MODELS="$OLLAMA_MODELS"
export OLLAMA_HOST="127.0.0.1:11434"
if ! pgrep -f "ollama serve" > /dev/null; then
    echo "Starting Ollama..."
    nohup ollama serve > "$HOME/.ollama.log" 2>&1 &
    sleep 2
    echo "Ollama started."
else
    echo "Ollama already running."
fi
EOF
    chmod +x "$LAUNCHER"
    "$LAUNCHER"
else
    info "Configuring systemd service for Ollama"
    sudo mkdir -p /etc/systemd/system/ollama.service.d
    sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null <<EOF
[Service]
Environment="OLLAMA_MODELS=$OLLAMA_MODELS"
Environment="OLLAMA_HOST=127.0.0.1:11434"
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable ollama
    sudo systemctl restart ollama
fi

# ----- Create runner scripts -----------------------------------------
info "Creating helper scripts in $BIN_DIR"

cat > "$BIN_DIR/run-gguf" <<'EOF'
#!/usr/bin/env python3
"""
Simple script to run GGUF models using llama-cpp-python.
Usage:
  run-gguf <model.gguf> [prompt]
If no arguments, list available models in ~/local-llm-models/gguf
"""
import sys
import os
import glob
from pathlib import Path

MODEL_DIR = os.path.expanduser("~/local-llm-models/gguf")

def list_models():
    models = glob.glob(os.path.join(MODEL_DIR, "*.gguf"))
    if not models:
        print("No GGUF models found in", MODEL_DIR)
        return
    print("Available GGUF models:")
    for m in sorted(models):
        print("  ", os.path.basename(m))

if len(sys.argv) < 2:
    list_models()
    sys.exit(0)

model_path = sys.argv[1]
if not os.path.isabs(model_path):
    model_path = os.path.join(MODEL_DIR, model_path)
if not os.path.exists(model_path):
    print(f"Model not found: {model_path}")
    list_models()
    sys.exit(1)

prompt = " ".join(sys.argv[2:]) if len(sys.argv) > 2 else "Hello, how are you?"

try:
    from llama_cpp import Llama
    llm = Llama(model_path=model_path, verbose=False)
    output = llm(prompt, max_tokens=256, echo=True)
    print(output["choices"][0]["text"])
except ImportError:
    print("llama-cpp-python not installed. Please run: pip install llama-cpp-python")
    sys.exit(1)
EOF
chmod +x "$BIN_DIR/run-gguf"

cat > "$BIN_DIR/local-models-info" <<'EOF'
#!/bin/bash
echo "=== Ollama Models ==="
if command -v ollama &> /dev/null; then
    ollama list 2>/dev/null || echo "Ollama not running or no models"
else
    echo "Ollama not installed"
fi
echo ""
echo "=== GGUF Models in ~/local-llm-models/gguf ==="
ls -lh ~/local-llm-models/gguf/*.gguf 2>/dev/null | awk '{print $9 " (" $5 ")"}' || echo "No GGUF models found"
echo ""
echo "=== Disk Usage ==="
du -sh ~/local-llm-models 2>/dev/null || echo "Model directory not found"
EOF
chmod +x "$BIN_DIR/local-models-info"

# ----- Shell aliases -------------------------------------------------
info "Creating shell aliases in $ALIAS_FILE"
cat > "$ALIAS_FILE" <<'EOF'
# LLM aliases
alias ollama-list='ollama list'
alias ollama-pull='ollama pull'
alias ollama-run='ollama run'
alias gguf-list='ls -lh ~/local-llm-models/gguf/*.gguf 2>/dev/null | awk "{print \$NF}" || echo "No GGUF models"'
alias gguf-run='run-gguf'
alias ask='run-gguf'
alias llm-status='local-models-info'
alias llm-help='echo -e "Available commands:\n  ollama-list\n  ollama-pull <model>\n  ollama-run <model>\n  gguf-list\n  gguf-run <model.gguf> [prompt]\n  ask (same as gguf-run)\n  llm-status"'
EOF

# ----- Optional model download ---------------------------------------
echo ""
if ask_yes_no "Do you want to download two small example GGUF models (TinyLlama 1.1B and Phi-2 2.7B)?"; then
    info "Downloading example models to $GGUF_MODELS..."
    cd "$GGUF_MODELS"
    download_cmd=""
    if command -v wget &> /dev/null; then
        download_cmd="wget -q --show-progress"
    elif command -v curl &> /dev/null; then
        download_cmd="curl -# -O"
    else
        warn "Neither wget nor curl found, skipping downloads."
    fi
    if [[ -n "$download_cmd" ]]; then
        $download_cmd https://huggingface.co/TheBloke/TinyLlama-1.1B-GGUF/resolve/main/tinyllama-1.1b.Q4_K_M.gguf || warn "Failed to download TinyLlama"
        $download_cmd https://huggingface.co/TheBloke/phi-2-GGUF/resolve/main/phi-2.Q4_K_M.gguf || warn "Failed to download Phi-2"
        info "Downloads completed (some may have failed)."
    fi
fi

# ====================================================================
#  QUALITY OF LIFE TOOLS (optional)
# ====================================================================
echo ""
if ask_yes_no "Do you want to install additional quality-of-life tools (zsh, file browser, web browser, htop, tmux, etc.)?"; then
    info "Installing quality-of-life tools..."

    # Install packages
    sudo apt install -y zsh htop tmux tree ranger w3m w3m-img

    # --- ZSH & Oh My Zsh ---
    if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
        info "Installing Oh My Zsh (unattended)..."
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    else
        info "Oh My Zsh already installed, skipping."
    fi

    # Install useful zsh plugins
    ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
    if [[ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]]; then
        info "Installing zsh-syntax-highlighting plugin..."
        git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
    fi
    if [[ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]]; then
        info "Installing zsh-autosuggestions plugin..."
        git clone https://github.com/zsh-users/zsh-autosuggestions.git "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
    fi

    # Update .zshrc to enable plugins and source our aliases
    if [[ -f "$HOME/.zshrc" ]]; then
        # Enable common plugins
        sed -i 's/^plugins=(git)/plugins=(git zsh-syntax-highlighting zsh-autosuggestions)/' "$HOME/.zshrc" || true
        # Add source for our aliases if not already present
        if ! grep -q "source $ALIAS_FILE" "$HOME/.zshrc"; then
            echo -e "\n# Load local LLM aliases\n[ -f $ALIAS_FILE ] && source $ALIAS_FILE" >> "$HOME/.zshrc"
        fi
    fi

    # --- Optionally set zsh as default shell (requires password) ---
    if [[ "$SHELL" != "$(which zsh)" ]]; then
        if ask_yes_no "Do you want to set zsh as your default shell? (you may need to enter your password)"; then
            chsh -s "$(which zsh)" || warn "Failed to set zsh as default shell. You can do it manually with: chsh -s $(which zsh)"
        fi
    fi

    # --- Ranger file browser configuration (optional) ---
    ranger --copy-config=all 2>/dev/null || true

    info "Quality-of-life tools installed."
fi

# ----- Final validation ----------------------------------------------
info "Validating installation..."

# Check Ollama
if [[ "$WSL2" == true ]]; then
    if pgrep -f "ollama serve" > /dev/null; then
        info "Ollama is running (background process)."
    else
        warn "Ollama is not running. Start it with: $BIN_DIR/ollama-start"
    fi
else
    if systemctl is-active --quiet ollama; then
        info "Ollama service is active."
    else
        warn "Ollama service is not running. Check with: sudo systemctl status ollama"
    fi
fi

# Check llama-cpp-python
if python3 -c "import llama_cpp" 2>/dev/null; then
    info "llama-cpp-python is importable."
else
    warn "llama-cpp-python import failed. Please check the virtual environment."
fi

# ----- Final message -------------------------------------------------
cat << EOF

🎉 Local LLM setup complete!

Important paths:
  Models base:     $MODEL_BASE
  GGUF models:     $GGUF_MODELS
  Ollama models:   $OLLAMA_MODELS
  Virtual env:     $VENV_DIR
  Helper scripts:  $BIN_DIR
  Aliases file:    $ALIAS_FILE

Next steps:
  1. Open a new terminal or run: source $ALIAS_FILE
  2. Use 'llm-help' to see available commands.
  3. Pull an Ollama model: ollama pull llama3.2
  4. Run it: ollama run llama3.2
  5. For GGUF models, place them in $GGUF_MODELS and run:
       gguf-run your-model.gguf "Your prompt"

If you installed quality-of-life tools:
  - Zsh with Oh My Zsh is ready (restart your shell or run 'zsh').
  - Use 'ranger' for a terminal file browser.
  - Use 'w3m' for a terminal web browser (e.g., w3m https://example.com).
  - Other tools: htop, tmux, tree.

If you're on WSL2 and reboot, remember to start Ollama with:
  ollama-start

Enjoy your private, local LLMs!
EOF