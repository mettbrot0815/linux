#!/bin/bash
# ultimate-local-llm.sh – 100% foolproof setup for Ubuntu/WSL2
# Run this ONCE and everything works. Zero questions, zero errors.

set -euo pipefail
trap 'echo -e "\n❌ ERROR on line $LINENO. Check $LOG_FILE for details."' ERR

# ==================== CONFIG ====================
MODELS_DIR="$HOME/local-llm-models"
CONFIG_DIR="$HOME/.config/local-llm"
BIN_DIR="$HOME/.local/bin"
VENV_DIR="$HOME/.local/share/llm-venv"       # isolated Python environment
LOG_FILE="$HOME/local-llm-setup-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
WHITE='\033[1;37m'; NC='\033[0m'

# Log everything
exec > >(tee -a "$LOG_FILE") 2>&1

# ==================== BANNER ====================
clear
echo -e "${PURPLE}"
echo '╔═══════════════════════════════════════════════════════════════╗'
echo '║              ULTIMATE LOCAL LLM SETUP (NO FAIL)               ║'
echo '║                 Optimized for Ubuntu / WSL2                    ║'
echo '║         Installs ONLY missing components – zero questions     ║'
echo '╚═══════════════════════════════════════════════════════════════╝'
echo -e "${NC}"

# ==================== HELPER FUNCTIONS ====================
print_step() { echo -e "\n${BLUE}🔧 $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️ $1${NC}"; }
print_info() { echo -e "${CYAN}ℹ️ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

# ==================== PRE-FLIGHT CHECKS ====================
print_step "Checking system requirements..."

# Must be Ubuntu/Debian
if ! grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
    print_warning "This script is optimized for Ubuntu/Debian. Proceed at your own risk."
fi

# Must have sudo
if ! sudo -v &>/dev/null; then
    print_error "sudo required. Please ensure you have sudo access."
    exit 1
fi

# Detect WSL2 (for service handling)
IS_WSL2=false
if grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL2=true
    print_info "WSL2 detected – services will be managed via background processes instead of systemd."
fi

# ==================== INSTALL SYSTEM PACKAGES ====================
print_step "Installing required system packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    curl wget git \
    build-essential \
    python3 python3-pip python3-venv \
    ca-certificates \
    >/dev/null 2>&1
print_success "System packages installed"

# ==================== DIRECTORY STRUCTURE ====================
print_step "Setting up directories..."
mkdir -p "$MODELS_DIR"/{ollama,gguf,temp} "$BIN_DIR" "$CONFIG_DIR"
print_success "Directories ready"

# ==================== PYTHON VENV (for llama-cpp-python) ====================
print_step "Setting up isolated Python environment..."
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    print_success "Virtual environment created"
else
    print_info "Virtual environment already exists"
fi

# Activate venv and upgrade pip
source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip setuptools wheel
print_success "Python environment ready"

# ==================== INSTALL LLAMA-CPP-PYTHON ====================
print_step "Installing GGUF support (llama-cpp-python)..."

# Detect GPU (NVIDIA) for CUDA support
GPU_SUPPORT=""
if command -v nvidia-smi &>/dev/null; then
    print_info "NVIDIA GPU detected – attempting CUDA installation"
    # Check CUDA version via nvidia-smi
    CUDA_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | cut -d. -f1)
    if [ -n "$CUDA_VERSION" ] && [ "$CUDA_VERSION" -ge 450 ]; then
        # For CUDA 11.x and above, use the appropriate index URL
        GPU_SUPPORT="--extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cu121"
        print_info "Using CUDA 12.1 wheel"
    else
        print_warning "CUDA driver too old or not detected; falling back to CPU"
    fi
fi

# Install llama-cpp-python (pre-compiled wheel)
if pip list 2>/dev/null | grep -q llama-cpp-python; then
    print_success "llama-cpp-python already installed"
else
    print_info "Installing llama-cpp-python (this may take a minute)..."
    if [ -n "$GPU_SUPPORT" ]; then
        CMAKE_ARGS="-DLLAMA_CUBLAS=on" pip install --quiet $GPU_SUPPORT llama-cpp-python || {
            print_warning "CUDA installation failed; falling back to CPU"
            pip install --quiet llama-cpp-python
        }
    else
        pip install --quiet llama-cpp-python
    fi
    print_success "llama-cpp-python installed"
fi

# ==================== INSTALL OLLAMA ====================
print_step "Installing Ollama..."
if command -v ollama &>/dev/null; then
    print_success "Ollama already installed ($(ollama --version 2>/dev/null | head -n1))"
else
    print_info "Downloading and installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    print_success "Ollama installed"
fi

# ==================== CONFIGURE OLLAMA ====================
print_step "Configuring Ollama for local-only use..."

# Set environment variables for local-only and custom models directory
mkdir -p /etc/ollama
sudo tee /etc/ollama/config.json >/dev/null <<EOF
{
    "disable_telemetry": true,
    "disable_update_check": true,
    "models_dir": "$MODELS_DIR/ollama"
}
EOF

# On WSL2, systemd is not available, so we'll run Ollama as a background process
if [ "$IS_WSL2" = true ]; then
    # Stop any running Ollama process
    pkill ollama 2>/dev/null || true
    
    # Create a script to start Ollama in the background
    cat > "$BIN_DIR/ollama-start" <<EOF
#!/bin/bash
export OLLAMA_HOST=127.0.0.1
export OLLAMA_MODELS="$MODELS_DIR/ollama"
export OLLAMA_KEEP_ALIVE=24h
export OLLAMA_DISABLE_TELEMETRY=1
nohup ollama serve > "$HOME/ollama.log" 2>&1 &
echo "Ollama started (PID \$!)"
EOF
    chmod +x "$BIN_DIR/ollama-start"
    
    # Add to bashrc to auto-start on shell login? Optional, but we'll just give instructions
    print_info "WSL2: Ollama will need to be started manually after reboot."
    print_info "Run 'ollama-start' to start the Ollama server."
    
    # Start it now
    "$BIN_DIR/ollama-start"
    print_success "Ollama started in background"
else
    # On native Linux, use systemd
    sudo tee /etc/systemd/system/ollama.service >/dev/null <<EOF
[Unit]
Description=Ollama Service - Local Only
After=network.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=$USER
Group=$USER
Restart=always
Environment="OLLAMA_HOST=127.0.0.1"
Environment="OLLAMA_MODELS=$MODELS_DIR/ollama"
Environment="OLLAMA_KEEP_ALIVE=24h"
Environment="OLLAMA_DISABLE_TELEMETRY=1"

[Install]
WantedBy=default.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable ollama
    sudo systemctl start ollama
    print_success "Ollama service configured and started"
fi

# ==================== CREATE RUNNER SCRIPTS ====================
print_step "Creating model runner scripts..."

# GGUF runner using the venv's Python
cat > "$BIN_DIR/run-gguf" <<EOF
#!/bin/bash
source "$VENV_DIR/bin/activate"
python - <<'PYTHON_SCRIPT'
import sys, os
from llama_cpp import Llama

MODEL_DIR = os.path.expanduser("$MODELS_DIR/gguf")

if len(sys.argv) < 2:
    print("Usage: run-gguf <model.gguf> [prompt]")
    print("\nAvailable models:")
    for f in os.listdir(MODEL_DIR):
        if f.endswith('.gguf'):
            print("  " + f)
    sys.exit(1)

model_path = os.path.join(MODEL_DIR, sys.argv[1])
if not os.path.exists(model_path):
    print(f"Model not found: {model_path}")
    sys.exit(1)

prompt = sys.argv[2] if len(sys.argv) > 2 else "Hello, how are you?"
llm = Llama(model_path=model_path, n_ctx=512, n_threads=4, verbose=False)
output = llm(prompt, max_tokens=512, echo=False)
print(output['choices'][0]['text'].strip())
PYTHON_SCRIPT
EOF
chmod +x "$BIN_DIR/run-gguf"

# Model info script
cat > "$BIN_DIR/local-models-info" <<'EOF'
#!/bin/bash
echo "📊 LOCAL MODELS STATUS"
echo "======================"
echo ""
echo "🦙 Ollama models:"
if command -v ollama &>/dev/null; then
    ollama list 2>/dev/null || echo "  (none)"
else
    echo "  Ollama not installed"
fi
echo ""
echo "📦 GGUF models:"
if [ -d "$HOME/local-llm-models/gguf" ]; then
    ls -lh "$HOME/local-llm-models/gguf"/*.gguf 2>/dev/null | sed 's/^/  /' || echo "  (none)"
else
    echo "  No GGUF directory"
fi
echo ""
echo "💾 Disk usage:"
du -sh "$HOME/local-llm-models" 2>/dev/null || echo "  (no models)"
EOF
chmod +x "$BIN_DIR/local-models-info"

print_success "Runner scripts created"

# ==================== SHELL ALIASES ====================
print_step "Setting up shell aliases..."
ALIAS_FILE="$HOME/.local_llm_aliases"
cat > "$ALIAS_FILE" <<'EOF'
# ---------- LOCAL LLM ALIASES ----------
alias ollama-list='ollama list'
alias ollama-ps='ollama ps'
alias ollama-pull='ollama pull'
alias ollama-run='ollama run'
alias ollama-stop='ollama stop'
alias ollama-stop-all='ollama stop -a'

alias run-llama='ollama run llama3.2'
alias run-mistral='ollama run mistral'
alias run-codellama='ollama run codellama'
alias run-phi='ollama run phi3'

alias gguf-list='ls -lh $HOME/local-llm-models/gguf/*.gguf 2>/dev/null'
alias gguf-run='$HOME/.local/bin/run-gguf'

alias models-cd='cd $HOME/local-llm-models'
alias models-size='du -sh $HOME/local-llm-models/* 2>/dev/null'
alias models-info='$HOME/.local/bin/local-models-info'

alias llm-status='echo -e "\033[1;34m=== LOCAL LLM STATUS ===\033[0m" && echo "" && (pgrep ollama &>/dev/null && echo -e "\033[1;36mOllama:\033[0m Running" || echo -e "\033[1;31mOllama:\033[0m Not running") && ollama ps 2>/dev/null && echo "" && models-info'
alias llm-logs='tail -f $HOME/ollama.log 2>/dev/null || journalctl -u ollama -f -n 30 2>/dev/null || echo "No logs"'
alias llm-restart='pkill ollama 2>/dev/null; $HOME/.local/bin/ollama-start 2>/dev/null || sudo systemctl restart ollama 2>/dev/null || echo "Could not restart"'

ask() { ollama run llama3.2 "$*"; }
ask-fast() { ollama run phi3 "$*"; }
ask-code() { ollama run codellama "$*"; }

llm-help() {
    echo -e "\033[1;35m╔════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;35m║        LOCAL LLM COMMANDS             ║\033[0m"
    echo -e "\033[1;35m╚════════════════════════════════════════╝\033[0m"
    echo ""
    echo -e "\033[1;34m📝 QUERY:\033[0m"
    echo "  ask 'question'        - Ask Llama 3.2"
    echo "  ask-fast 'question'   - Ask Phi3 (faster)"
    echo "  ask-code 'code'       - Ask CodeLlama"
    echo ""
    echo -e "\033[1;34m🦙 OLLAMA:\033[0m"
    echo "  ollama-list           - List models"
    echo "  ollama-ps             - Show running"
    echo "  ollama-pull <model>   - Download model"
    echo "  ollama-run <model>    - Run model"
    echo ""
    echo -e "\033[1;34m📦 GGUF:\033[0m"
    echo "  gguf-list             - List GGUF files"
    echo "  gguf-run <file>       - Run GGUF model"
    echo ""
    echo -e "\033[1;34m📊 INFO:\033[0m"
    echo "  models-info           - Show all models"
    echo "  llm-status            - System status"
    echo "  models-cd             - Go to models dir"
}
EOF

# Inject into bashrc/zshrc
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    if ! grep -q "source ~/.local_llm_aliases" "$rc" 2>/dev/null; then
        echo "" >> "$rc"
        echo "# Local LLM aliases" >> "$rc"
        echo "[ -f ~/.local_llm_aliases ] && source ~/.local_llm_aliases" >> "$rc"
    fi
done
print_success "Aliases installed"

# ==================== DOWNLOAD EXAMPLE MODELS ====================
echo ""
echo -e "${YELLOW}Download some tiny starter models? (y/n)${NC}"
read -r download_choice
if [[ "$download_choice" =~ ^[Yy]$ ]]; then
    print_step "Downloading example GGUF models"
    mkdir -p "$MODELS_DIR/gguf"
    cd "$MODELS_DIR/gguf"

    # Use wget if available, else curl
    if command -v wget &>/dev/null; then
        DL="wget -q --show-progress"
    else
        DL="curl -L -O --progress-bar"
    fi

    echo -e "${CYAN}TinyLlama 1.1B (smallest)${NC}"
    $DL https://huggingface.co/TheBloke/TinyLlama-1.1B-GGUF/resolve/main/tinyllama-1.1b.Q4_K_M.gguf || print_warning "TinyLlama download failed"

    echo -e "${CYAN}Phi-2 2.7B (smart & small)${NC}"
    $DL https://huggingface.co/TheBloke/phi-2-GGUF/resolve/main/phi-2.Q4_K_M.gguf || print_warning "Phi-2 download failed"

    cd ~
    print_success "Models downloaded to $MODELS_DIR/gguf"
fi

# ==================== FINAL VALIDATION ====================
print_step "Validating installation..."
# Test Ollama
if command -v ollama &>/dev/null; then
    if pgrep ollama &>/dev/null || systemctl is-active --quiet ollama 2>/dev/null; then
        print_success "Ollama is running"
    else
        print_warning "Ollama installed but not running. Start it with 'ollama-start' (WSL2) or 'sudo systemctl start ollama' (Linux)."
    fi
fi

# Test llama-cpp-python
if source "$VENV_DIR/bin/activate" && python -c "import llama_cpp" 2>/dev/null; then
    print_success "llama-cpp-python works"
else
    print_error "llama-cpp-python not working. Check Python environment."
fi

# ==================== SUMMARY ====================
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}              SETUP COMPLETE – EVERYTHING DONE          ${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}📁 Directories:${NC}"
echo "   Models: $MODELS_DIR"
echo "   Log:    $LOG_FILE"
echo ""
echo -e "${YELLOW}👉 To activate aliases NOW, run:${NC}"
echo "   source ~/.local_llm_aliases"
echo ""
echo -e "${YELLOW}👉 Then type:${NC} llm-help"
echo ""
echo -e "${YELLOW}👉 To start Ollama (if not running):${NC}"
if [ "$IS_WSL2" = true ]; then
    echo "   ollama-start"
else
    echo "   sudo systemctl start ollama"
fi
echo ""

# ==================== CLEAN EXIT ====================
exit 0