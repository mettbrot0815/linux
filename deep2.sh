#!/usr/bin/env bash
set -euo pipefail

# ---------- Configuration ----------
LOG_FILE="$HOME/local-llm-setup-$(date +%Y%m%d-%H%M%S).log"
VENV_DIR="$HOME/.local/share/llm-venv"
MODEL_BASE="$HOME/local-llm-models"
OLLAMA_MODELS="$MODEL_BASE/ollama"
GGUF_MODELS="$MODEL_BASE/gguf"
TEMP_DIR="$MODEL_BASE/temp"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/local-llm"
ALIAS_FILE="$HOME/.local_llm_aliases"
MODEL_CONFIG="$CONFIG_DIR/selected_model.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------- Helper Functions ----------
log() { echo -e "$(date +'%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"; }
info() { echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

is_wsl2() { grep -qi microsoft /proc/version 2>/dev/null && uname -r | grep -qi wsl2; }
ask_yes_no() { local ans; read -p "$1 (y/N) " -n 1 -r ans; echo; [[ "$ans" =~ ^[Yy]$ ]]; }

# Verify a command exists
check_command() {
    if ! command -v "$1" &>/dev/null; then
        warn "$1 is not available. $2"
        return 1
    fi
    return 0
}

# Verify Python module import
check_python_module() {
    python3 -c "import $1" 2>/dev/null && return 0 || return 1
}

# ---------- CUDA Environment Setup ----------
setup_cuda_env() {
    # Find CUDA installation directory
    local cuda_candidates=(
        "/usr/local/cuda"
        "/usr/local/cuda-"[0-9.]*
        "/usr/lib/cuda"
        "/opt/cuda"
    )
    local cuda_lib_dir=""
    for dir in "${cuda_candidates[@]}"; do
        for d in $dir; do
            if [ -d "$d" ]; then
                if [ -f "$d/lib64/libcudart.so.12" ]; then
                    cuda_lib_dir="$d/lib64"
                    break 2
                elif [ -f "$d/lib/libcudart.so.12" ]; then
                    cuda_lib_dir="$d/lib"
                    break 2
                fi
            fi
        done
    done

    if [ -n "$cuda_lib_dir" ]; then
        export LD_LIBRARY_PATH="$cuda_lib_dir:${LD_LIBRARY_PATH:-}"
        info "CUDA libraries found at $cuda_lib_dir"
        local cuda_bin_dir="${cuda_lib_dir%/lib*}/bin"
        if [ -d "$cuda_bin_dir" ]; then
            export PATH="$cuda_bin_dir:$PATH"
        fi
        # Persist in shell config
        for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
            if [ -f "$rc" ] && ! grep -q "export PATH=.*cuda" "$rc"; then
                echo "
# CUDA toolkit
export PATH=${cuda_bin_dir:-/usr/local/cuda/bin}:\$PATH
export LD_LIBRARY_PATH=$cuda_lib_dir:\$LD_LIBRARY_PATH" >> "$rc"
            fi
        done
        return 0
    else
        warn "Could not find CUDA libraries. Please ensure CUDA toolkit is installed correctly."
        return 1
    fi
}

# ---------- Pre‑flight ----------
if [ "$EUID" -eq 0 ]; then
    error "Please do not run this script as root. Run as a normal user with sudo access."
fi

info "Starting local LLM setup – log at $LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

if ! command -v sudo &>/dev/null; then error "sudo is required."; fi

# ---------- System Dependencies ----------
info "Installing core system packages..."
sudo apt update
sudo apt install -y curl wget git build-essential python3 python3-pip python3-venv

# Double-check system dependencies
MISSING_SYS=()
for cmd in curl wget git python3 pip; do
    if ! command -v $cmd &>/dev/null; then
        MISSING_SYS+=($cmd)
    fi
done
if [ ${#MISSING_SYS[@]} -gt 0 ]; then
    error "System dependencies missing: ${MISSING_SYS[*]}. Please install them manually."
else
    info "All core system dependencies are present."
fi

# ---------- Directory Setup ----------
mkdir -p "$OLLAMA_MODELS" "$GGUF_MODELS" "$TEMP_DIR" "$BIN_DIR" "$CONFIG_DIR"

# ---------- NVIDIA Driver Check ----------
if ! command -v nvidia-smi &>/dev/null; then
    warn "nvidia-smi not found – NVIDIA driver may be missing."
    if ask_yes_no "Install NVIDIA driver (recommended version) now?"; then
        info "Installing NVIDIA driver via ubuntu-drivers..."
        sudo apt install -y ubuntu-drivers-common
        sudo ubuntu-drivers autoinstall
        warn "Driver installed – a reboot is required. After reboot, re-run this script."
        exit 0
    else
        error "Cannot proceed without NVIDIA driver. Install it manually and re-run."
    fi
else
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
    info "Found GPU: $GPU_NAME"
    DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)
    info "NVIDIA driver version: $DRIVER_VERSION"
fi

# ---------- CUDA Toolkit Installation (driver NOT touched) ----------
if ! command -v nvcc &>/dev/null; then
    info "CUDA toolkit not found – installing via NVIDIA repository (driver not touched)."

    UBUNTU_VERSION=$(lsb_release -rs)
    if [[ "$UBUNTU_VERSION" != "22.04" && "$UBUNTU_VERSION" != "24.04" ]]; then
        error "Unsupported Ubuntu version. Please install CUDA toolkit manually."
    fi

    wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_VERSION//./}/x86_64/cuda-keyring_1.1-1_all.deb
    sudo dpkg -i cuda-keyring_1.1-1_all.deb
    rm cuda-keyring_1.1-1_all.deb
    sudo apt update

    CUDA_PKG=$(apt-cache search --names-only '^cuda-toolkit-[0-9]+-[0-9]+$' | sort -V | tail -n1 | cut -d' ' -f1)
    if [ -n "$CUDA_PKG" ]; then
        info "Installing $CUDA_PKG ..."
        sudo apt install -y "$CUDA_PKG"
    else
        warn "No versioned cuda-toolkit package found; installing cuda-toolkit (latest)."
        sudo apt install -y cuda-toolkit
    fi

    # --- FIX: Set up environment BEFORE verifying nvcc ---
    setup_cuda_env

    # Now verify CUDA toolkit installation
    if ! command -v nvcc &>/dev/null; then
        # Try to find nvcc manually in case setup_cuda_env missed it
        NVCC_PATH=$(find /usr/local -name nvcc -type f 2>/dev/null | head -n1)
        if [ -n "$NVCC_PATH" ]; then
            export PATH="$(dirname "$NVCC_PATH"):$PATH"
            info "Found nvcc at $NVCC_PATH and added to PATH."
        else
            error "CUDA toolkit installation failed – nvcc not found even after searching."
        fi
    fi
    info "CUDA toolkit installed successfully."
else
    info "CUDA toolkit already installed."
    # Ensure environment is set even if already installed
    setup_cuda_env
fi

# Double-check CUDA library
if ! ldconfig -p | grep -q libcudart.so.12; then
    warn "libcudart.so.12 not found in ldconfig cache. LD_LIBRARY_PATH is set to $LD_LIBRARY_PATH"
    # Attempt to find it manually
    if ! find /usr/local/cuda* -name 'libcudart.so.12' 2>/dev/null | grep -q .; then
        error "CUDA runtime library (libcudart.so.12) not found. CUDA toolkit may be incomplete."
    else
        info "CUDA runtime library found but not in ldconfig. Using LD_LIBRARY_PATH."
    fi
fi

# ---------- Python Virtual Environment ----------
info "Setting up Python venv at $VENV_DIR"
[ ! -d "$VENV_DIR" ] && python3 -m venv "$VENV_DIR"
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"
pip install --upgrade pip setuptools wheel

# Verify venv is active
if [[ "$VIRTUAL_ENV" != "$VENV_DIR" ]]; then
    error "Python virtual environment not activated correctly."
fi

# ---------- Install llama-cpp-python with CUDA ----------
info "Installing llama-cpp-python with CUDA support..."
if pip install llama-cpp-python \
    --index-url https://abetlen.github.io/llama-cpp-python/whl/cu121 \
    --extra-index-url https://pypi.org/simple; then
    info "Pre-built CUDA wheel installed."
else
    warn "Pre‑built wheel failed – building from source (may take a few minutes)..."
    CMAKE_ARGS="-DLLAMA_CUBLAS=on" pip install llama-cpp-python --no-cache-dir
fi

# Verify llama-cpp-python import
if check_python_module llama_cpp; then
    info "llama-cpp-python works."
else
    warn "llama-cpp-python import failed. Check CUDA library paths."
    # Provide diagnostic info
    python3 -c "import sys; print(sys.path)"
    echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
fi

# ---------- Install Ollama ----------
if ! command -v ollama &>/dev/null; then
    info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
else
    info "Ollama already installed."
fi

# Verify Ollama installation
if ! command -v ollama &>/dev/null; then
    error "Ollama installation failed."
fi

# ---------- Configure Ollama ----------
sudo mkdir -p /etc/ollama
sudo tee /etc/ollama/config.json > /dev/null <<EOF
{
    "disable_telemetry": true,
    "models": "$OLLAMA_MODELS"
}
EOF

if is_wsl2; then
    LAUNCHER="$BIN_DIR/ollama-start"
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

# Wait a moment for Ollama to start
sleep 3
if is_wsl2; then
    if pgrep -f "ollama serve" >/dev/null; then
        info "Ollama is running."
    else
        warn "Ollama not running. Start manually with: ollama-start"
    fi
else
    if systemctl is-active --quiet ollama; then
        info "Ollama service is active."
    else
        warn "Ollama service not active. Check with: sudo systemctl status ollama"
    fi
fi

# ---------- Helper Scripts ----------
cat > "$BIN_DIR/run-gguf" <<'EOF'
#!/usr/bin/env python3
import sys, os, glob, argparse
MODEL_DIR = os.path.expanduser("~/local-llm-models/gguf")
CONFIG_DIR = os.path.expanduser("~/.config/local-llm")

def list_models():
    models = glob.glob(os.path.join(MODEL_DIR, "*.gguf"))
    if not models:
        print("No GGUF models found in", MODEL_DIR)
        return
    print("Available GGUF models:")
    for m in sorted(models):
        size = os.path.getsize(m) / (1024**3)
        print(f"  {os.path.basename(m):<50} ({size:.1f} GB)")

def get_default_gpu_layers(model_name):
    cfg = os.path.join(CONFIG_DIR, "selected_model.conf")
    if os.path.exists(cfg):
        with open(cfg) as f:
            for line in f:
                if line.startswith("GPU_LAYERS="):
                    return int(line.split("=")[1].strip())
    return 35  # default for 12GB cards

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("model", nargs="?", help="Model filename")
    parser.add_argument("prompt", nargs="*", help="Prompt text")
    parser.add_argument("--gpu-layers", type=int, help="GPU layers")
    args = parser.parse_args()

    if not args.model:
        list_models()
        sys.exit(0)

    model_path = args.model
    if not os.path.isabs(model_path):
        model_path = os.path.join(MODEL_DIR, model_path)
    if not os.path.exists(model_path):
        print(f"Model not found: {model_path}")
        list_models()
        sys.exit(1)

    prompt = " ".join(args.prompt) if args.prompt else "Hello, how are you?"
    gpu_layers = args.gpu_layers or get_default_gpu_layers(os.path.basename(model_path))

    try:
        from llama_cpp import Llama
        llm = Llama(model_path=model_path, n_gpu_layers=gpu_layers, verbose=False, n_ctx=4096)
        output = llm(prompt, max_tokens=512, echo=True, temperature=0.7, top_p=0.95)
        print(output["choices"][0]["text"])
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)
EOF
chmod +x "$BIN_DIR/run-gguf"

cat > "$BIN_DIR/local-models-info" <<'EOF'
#!/bin/bash
echo "=== Ollama Models ==="
ollama list 2>/dev/null || echo "No Ollama models"
echo ""
echo "=== GGUF Models ==="
ls -lh ~/local-llm-models/gguf/*.gguf 2>/dev/null | awk '{print $9 " (" $5 ")"}' || echo "None"
echo ""
echo "=== Disk Usage ==="
du -sh ~/local-llm-models 2>/dev/null || echo "No models"
if [ -f ~/.config/local-llm/selected_model.conf ]; then
    echo ""
    echo "=== Selected Model ==="
    source ~/.config/local-llm/selected_model.conf
    echo "Model: $MODEL_NAME ($MODEL_SIZE)"
    echo "GPU Layers: $GPU_LAYERS"
fi
EOF
chmod +x "$BIN_DIR/local-models-info"

# ---------- Shell Aliases ----------
cat > "$ALIAS_FILE" <<'EOF'
# LLM aliases
alias ollama-list='ollama list'
alias ollama-pull='ollama pull'
alias ollama-run='ollama run'
alias gguf-list='ls -lh ~/local-llm-models/gguf/*.gguf 2>/dev/null | awk "{print \$NF}" || echo "No GGUF models"'
alias gguf-run='run-gguf'
alias ask='run-gguf'
alias llm-status='local-models-info'
alias load-model='[ -f ~/.config/local-llm/selected_model.conf ] && source ~/.config/local-llm/selected_model.conf && echo "Loaded $MODEL_NAME. Use: run-model \"prompt\"" || echo "No model selected"'
alias run-model='[ -f ~/.config/local-llm/selected_model.conf ] && source ~/.config/local-llm/selected_model.conf && run-gguf "$MODEL_FILENAME"'
alias llm-help='echo -e "Available:\n  ollama-list\n  ollama-pull\n  ollama-run\n  gguf-list\n  gguf-run <model> [prompt] [--gpu-layers N]\n  ask (same as gguf-run)\n  llm-status\n  load-model\n  run-model"'
EOF

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] && ! grep -q "source $ALIAS_FILE" "$rc" && echo -e "\n# Load local LLM aliases\n[ -f $ALIAS_FILE ] && source $ALIAS_FILE" >> "$rc"
done

# ---------- Model Selection Menu ----------
if ask_yes_no "Do you want to select an uncensored model optimized for RTX 3060 12GB?"; then
    echo -e "\n${BLUE}=== Select a Model ===${NC}\n"
    echo "1) Qwen2.5-14B-Instruct (Q4_K_M) - 25-30 tok/s"
    echo "2) Mistral-Small-22B (Q4_K_M) - 15-20 tok/s"
    echo "3) Mistral-Nemo-12B (Q5_K_M) - 30-35 tok/s"
    echo "4) SOLAR-10.7B-uncensored (Q6_K) - 30 tok/s"
    echo "5) Wizard-Vicuna-30B-Uncensored (Q3_K_S)* - 8-12 tok/s (CPU offload)"
    echo "6) Qwen3-8B-abliterated (Q6_K) - 35+ tok/s"
    echo "7) Midnight-Miqu-70B (Q4_K_M)† - needs 64GB RAM"
    echo "8) Skip"
    echo ""
    read -p "Enter choice [1-8]: " choice

    case $choice in
        1) NAME="Qwen2.5-14B-Instruct"; URL="https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF/resolve/main/qwen2.5-14b-instruct-q4_k_m.gguf"; FILE="qwen2.5-14b-instruct-q4_k_m.gguf"; SIZE="14B"; LAYERS="35" ;;
        2) NAME="Mistral-Small-22B"; URL="https://huggingface.co/bartowski/Mistral-Small-22B-ArliAI-RPMax-v1.1-GGUF/resolve/main/Mistral-Small-22B-ArliAI-RPMax-v1.1-Q4_K_M.gguf"; FILE="mistral-small-22b-q4_k_m.gguf"; SIZE="22B"; LAYERS="35" ;;
        3) NAME="Mistral-Nemo-12B"; URL="https://huggingface.co/bartowski/Mistral-Nemo-Instruct-2407-GGUF/resolve/main/Mistral-Nemo-Instruct-2407-Q5_K_M.gguf"; FILE="mistral-nemo-12b-q5_k_m.gguf"; SIZE="12B"; LAYERS="40" ;;
        4) NAME="SOLAR-10.7B-uncensored"; URL="https://huggingface.co/mradermacher/SOLAR-10.7B-Instruct-v1.0-uncensored-GGUF/resolve/main/SOLAR-10.7B-Instruct-v1.0-uncensored.Q6_K.gguf"; FILE="solar-10.7b-q6_k.gguf"; SIZE="11B"; LAYERS="48" ;;
        5) NAME="Wizard-Vicuna-30B-Uncensored"; URL="https://huggingface.co/TheBloke/Wizard-Vicuna-30B-Uncensored-GGUF/resolve/main/wizard-vicuna-30b-uncensored.Q3_K_S.gguf"; FILE="wizard-vicuna-30b-q3_k_s.gguf"; SIZE="30B"; LAYERS="25"; warn "30B model – expects 8-12 tok/s with CPU offload." ;;
        6) NAME="Qwen3-8B-abliterated"; URL="https://huggingface.co/mradermacher/Qwen3-8B-192k-Context-6X-Josiefied-Uncensored-i1-GGUF/resolve/main/Qwen3-8B-192k-Context-6X-Josiefied-Uncensored-i1.Q6_K.gguf"; FILE="qwen3-8b-abliterated-q6_k.gguf"; SIZE="8B"; LAYERS="36" ;;
        7) NAME="Midnight-Miqu-70B"; URL="https://huggingface.co/bartowski/Midnight-Miqu-70B-v1.5-GGUF/resolve/main/Midnight-Miqu-70B-v1.5.Q4_K_M.gguf"; FILE="midnight-miqu-70b-q4_k_m.gguf"; SIZE="70B"; LAYERS="15"; warn "70B requires 48GB+ RAM – expect low speed." ;;
        8) info "Skipping model selection."; MODEL_SKIP=1 ;;
        *) warn "Invalid choice, skipping."; MODEL_SKIP=1 ;;
    esac

    if [[ -z "${MODEL_SKIP:-}" ]]; then
        cat > "$MODEL_CONFIG" <<EOF
MODEL_NAME="$NAME"
MODEL_URL="$URL"
MODEL_FILENAME="$FILE"
MODEL_SIZE="$SIZE"
GPU_LAYERS="$LAYERS"
EOF
        if ask_yes_no "Download $NAME ($FILE ~? GB) now?"; then
            info "Downloading to $GGUF_MODELS..."
            cd "$GGUF_MODELS"
            if command -v wget &>/dev/null; then
                wget --tries=3 --timeout=30 -q --show-progress "$URL" -O "$FILE" || warn "Download failed. Try manual download."
            else
                curl -L --retry 3 --connect-timeout 30 -# "$URL" -o "$FILE" || warn "Download failed. Try manual download."
            fi
            if [ -f "$FILE" ]; then
                info "Download complete: $(du -h "$FILE" | cut -f1)"
            fi
        fi
    fi
fi

# ---------- Quality of Life Tools (including mousepad, thunar, ezsh, fzf-tab) ----------
if ask_yes_no "Install quality-of-life tools (zsh, ranger, w3m, htop, tmux, tree, mousepad, thunar)?"; then
    info "Installing QoL tools..."
    sudo apt install -y zsh htop tmux tree ranger w3m w3m-img mousepad thunar

    # Verify installations
    for tool in zsh htop tmux tree ranger w3m; do
        if ! command -v "$tool" &>/dev/null; then
            warn "$tool installation may have failed."
        fi
    done

    # ---------- Additional Zsh Customizations ----------
    if ask_yes_no "Install ezsh (alternative Zsh framework) instead of Oh My Zsh?"; then
        info "Installing ezsh..."
        if git clone https://github.com/jotyGill/ezsh "$TEMP_DIR/ezsh"; then
            cd "$TEMP_DIR/ezsh"
            ./install.sh || warn "ezsh installation failed. Continuing with Oh My Zsh."
            cd "$HOME"
            rm -rf "$TEMP_DIR/ezsh"
        else
            warn "Failed to clone ezsh repository."
        fi
    else
        # Install Oh My Zsh if not present
        if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
            info "Installing Oh My Zsh..."
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        else
            info "Oh My Zsh already installed."
        fi

        # Install useful zsh plugins
        ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
        [ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ] && git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
        [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ] && git clone https://github.com/zsh-users/zsh-autosuggestions.git "$ZSH_CUSTOM/plugins/zsh-autosuggestions"

        # Install fzf-tab if requested
        if ask_yes_no "Install fzf-tab (fuzzy tab completion) for Zsh?"; then
            info "Installing fzf-tab..."
            if [ -d "$ZSH_CUSTOM" ]; then
                git clone https://github.com/Aloxaf/fzf-tab "$ZSH_CUSTOM/plugins/fzf-tab"
                # Enable the plugin in .zshrc
                if [ -f "$HOME/.zshrc" ]; then
                    sed -i 's/^plugins=(\(.*\))/plugins=(\1 fzf-tab)/' "$HOME/.zshrc" 2>/dev/null || true
                    # Also install fzf binary if not present
                    if ! command -v fzf &>/dev/null; then
                        info "Installing fzf..."
                        git clone --depth 1 https://github.com/junegunn/fzf.git "$TEMP_DIR/fzf"
                        "$TEMP_DIR/fzf/install" --all --no-bash --no-fish --no-update-rc
                        rm -rf "$TEMP_DIR/fzf"
                    fi
                fi
            fi
        fi

        # Update .zshrc to enable plugins
        if [ -f "$HOME/.zshrc" ]; then
            sed -i 's/^plugins=(git)/plugins=(git zsh-syntax-highlighting zsh-autosuggestions)/' "$HOME/.zshrc" 2>/dev/null || true
            ! grep -q "source $ALIAS_FILE" "$HOME/.zshrc" && echo -e "\n[ -f $ALIAS_FILE ] && source $ALIAS_FILE" >> "$HOME/.zshrc"
        fi
    fi

    # Optionally set zsh as default
    if [[ "$SHELL" != "$(which zsh)" ]] && ask_yes_no "Set zsh as default shell?"; then
        chsh -s "$(which zsh)" || warn "Failed to set zsh. Manual: chsh -s $(which zsh)"
    fi

    ranger --copy-config=all 2>/dev/null || true
fi

# ---------- Final Validation (Double-Check) ----------
info "Performing final validation of all components..."

# 1. CUDA libraries
if ! ldconfig -p | grep -q libcudart.so.12; then
    warn "libcudart.so.12 not found in ldconfig cache. If you encounter errors, set LD_LIBRARY_PATH as above."
fi

# 2. Python venv and llama-cpp
if [[ "$VIRTUAL_ENV" == "$VENV_DIR" ]] && check_python_module llama_cpp; then
    info "llama-cpp-python is importable."
else
    warn "llama-cpp-python import failed. Run: source $VENV_DIR/bin/activate and check manually."
fi

# 3. Ollama
if is_wsl2; then
    if pgrep -f "ollama serve" >/dev/null; then
        info "Ollama is running."
    else
        warn "Ollama not running. Start with: ollama-start"
    fi
else
    if systemctl is-active --quiet ollama; then
        info "Ollama service is active."
    else
        warn "Ollama service not active. Check with: sudo systemctl status ollama"
    fi
fi

# 4. Helper scripts
for script in "$BIN_DIR/run-gguf" "$BIN_DIR/local-models-info"; do
    if [ -x "$script" ]; then
        info "$(basename "$script") is executable."
    else
        warn "$script is missing or not executable."
    fi
done

# 5. Aliases file
if [ -f "$ALIAS_FILE" ]; then
    info "Aliases file exists."
else
    warn "Aliases file missing."
fi

# ---------- Final Output ----------
cat << EOF

${GREEN}✅ Local LLM setup complete!${NC}

Paths:
  Models base:     $MODEL_BASE
  GGUF models:     $GGUF_MODELS
  Ollama models:   $OLLAMA_MODELS
  Virtual env:     $VENV_DIR
  Aliases file:    $ALIAS_FILE

EOF

if [ -f "$MODEL_CONFIG" ]; then
    source "$MODEL_CONFIG"
    cat << EOF
Your selected model: ${GREEN}$MODEL_NAME${NC} ($MODEL_SIZE)
  - File: $MODEL_FILENAME
  - GPU layers: $GPU_LAYERS
  - Quick test: ${YELLOW}run-model "What is AI?"${NC}
EOF
fi

cat << EOF

Next steps:
  - Open a new terminal or run: ${YELLOW}source $ALIAS_FILE${NC}
  - Use ${YELLOW}llm-help${NC} for available commands.
  - On WSL2 after reboot: ${YELLOW}ollama-start${NC}

Enjoy your uncensored local LLMs on your RTX 3060 12GB! 🚀
EOF