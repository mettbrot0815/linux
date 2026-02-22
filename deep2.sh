#!/usr/bin/env bash
# =============================================================================
# Local LLM Setup Script — Optimised for i7-7700K + 16 GB RAM + RTX 3060 12 GB
# Targets: Ubuntu 22.04 / 24.04
# =============================================================================

# ---------- Strict mode -------------------------------------------------------
set -uo pipefail

# =============================================================================
# HARDWARE PROFILE — i7-7700K + 16 GB RAM + RTX 3060 12 GB
# =============================================================================
HW_THREADS=8
HW_BATCH=512
HW_CTX=4096
HW_GPU_VRAM_GB=12
HW_SYS_RAM_GB=16

# ---------- Configuration -----------------------------------------------------
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

# ---------- Colors ------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------- Logging -----------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log()   { echo -e "$(date +'%Y-%m-%d %H:%M:%S') $1"; }
info()  { log "${GREEN}[INFO]${NC}  $1"; }
warn()  { log "${YELLOW}[WARN]${NC}  $1"; }
error() { log "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
          echo -e "${BLUE}  ▶  $1${NC}"; \
          echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ---------- Helper: safe yes/no prompt ----------------------------------------
ask_yes_no() {
    local prompt="$1" ans=""
    if [[ ! -t 0 ]]; then
        warn "Non-interactive shell — treating '$prompt' as No."
        return 1
    fi
    read -r -p "$(echo -e "${YELLOW}?${NC} $prompt (y/N) ")" -n 1 ans
    echo
    [[ "$ans" =~ ^[Yy]$ ]] && return 0 || return 1
}

# ---------- Helper: retry a command up to N times ----------------------------
retry() {
    local n="${1}" delay="${2}"; shift 2
    local attempt=1
    while true; do
        if "$@"; then return 0; fi
        if (( attempt >= n )); then
            warn "Command failed after $n attempts: $*"
            return 1
        fi
        warn "Attempt $attempt/$n failed — retrying in ${delay}s…"
        sleep "$delay"
        attempt=$(( attempt + 1 ))
    done
}

# ---------- Helper: check for a command ---------------------------------------
check_command() {
    if ! command -v "$1" &>/dev/null; then
        warn "$1 not found. ${2:-}"
        return 1
    fi
    return 0
}

# ---------- Helper: check Python module import --------------------------------
check_python_module() {
    "$VENV_DIR/bin/python3" -c "import $1" 2>/dev/null
}

# ---------- WSL2 detection ----------------------------------------------------
is_wsl2() {
    grep -qi microsoft /proc/version 2>/dev/null && \
    uname -r 2>/dev/null | grep -qi "wsl2"
}

# =============================================================================
# PRE-FLIGHT
# =============================================================================
step "Pre-flight checks"

if [[ "${EUID}" -eq 0 ]]; then
    error "Do not run as root. Use a normal user with sudo access."
fi

if ! command -v sudo &>/dev/null; then
    error "sudo is required but not found."
fi

# Optional: quick internet connectivity check
if ! ping -c 1 google.com &>/dev/null; then
    warn "No internet connection detected. Some downloads may fail."
fi

info "Starting local LLM setup — log: $LOG_FILE"
info "Hardware profile: i7-7700K (${HW_THREADS}t / AVX2) | ${HW_SYS_RAM_GB}GB RAM | RTX 3060 ${HW_GPU_VRAM_GB}GB VRAM"
is_wsl2 && info "WSL2 environment detected." || info "Native Linux environment detected."

# =============================================================================
# SYSTEM DEPENDENCIES
# =============================================================================
step "System dependencies"

info "Running apt update…"
sudo apt-get update -qq || warn "apt update returned non-zero (may be harmless)."

PKGS=(
    curl wget git
    build-essential cmake ninja-build
    python3 python3-pip python3-venv
    lsb-release
    libopenblas-dev
)
info "Installing: ${PKGS[*]}"
sudo apt-get install -y "${PKGS[@]}" || warn "Some packages may have failed — continuing."

MISSING_SYS=()
for cmd in curl wget git python3 pip3; do
    command -v "$cmd" &>/dev/null || MISSING_SYS+=("$cmd")
done
if [[ ${#MISSING_SYS[@]} -gt 0 ]]; then
    error "Critical dependencies still missing: ${MISSING_SYS[*]}. Install them and re-run."
else
    info "All core system dependencies present."
fi

# =============================================================================
# DIRECTORY SETUP
# =============================================================================
step "Directory setup"
mkdir -p "$OLLAMA_MODELS" "$GGUF_MODELS" "$TEMP_DIR" "$BIN_DIR" "$CONFIG_DIR"
info "Directories ready under $MODEL_BASE"

# =============================================================================
# NVIDIA DRIVER CHECK
# =============================================================================
step "NVIDIA driver"

if ! check_command nvidia-smi "NVIDIA driver may be missing."; then
    if ask_yes_no "Install NVIDIA driver via ubuntu-drivers now?"; then
        info "Installing ubuntu-drivers-common…"
        sudo apt-get install -y ubuntu-drivers-common
        sudo ubuntu-drivers autoinstall || warn "ubuntu-drivers autoinstall failed — try manually."
        warn "Driver installed — a REBOOT is required. Re-run this script after reboot."
        exit 0
    else
        error "Cannot continue without NVIDIA driver. Install it and re-run."
    fi
else
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo "Unknown")
    DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || echo "Unknown")
    VRAM_MiB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ' || echo "0")
    info "GPU: $GPU_NAME | Driver: $DRIVER_VER | VRAM: ${VRAM_MiB} MiB"

    if (( VRAM_MiB > 0 && VRAM_MiB < 10000 )); then
        warn "Detected less than 10 GB VRAM (${VRAM_MiB} MiB). GPU layer counts may need reducing."
    fi
fi

# =============================================================================
# CUDA TOOLKIT
# =============================================================================
step "CUDA toolkit"

setup_cuda_env() {
    local lib_dir=""
    while IFS= read -r -d '' path; do
        lib_dir="$(dirname "$path")"
        break
    done < <(find /usr/local /usr/lib /opt -maxdepth 6 \
                  -name "libcudart.so.12" -print0 2>/dev/null)

    if [[ -z "$lib_dir" ]]; then
        warn "libcudart.so.12 not found anywhere — CUDA env not configured."
        return 1
    fi

    export LD_LIBRARY_PATH="$lib_dir:${LD_LIBRARY_PATH:-}"
    info "CUDA libs: $lib_dir"

    local base_dir
    base_dir="$(echo "$lib_dir" | sed 's|/lib[^/]*$||')"
    local bin_dir="$base_dir/bin"
    if [[ -d "$bin_dir" ]]; then
        export PATH="$bin_dir:$PATH"
        info "CUDA bin: $bin_dir"
    fi

    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$rc" ]] && ! grep -q "# CUDA toolkit — local-llm-setup" "$rc"; then
            {
              echo ""
              echo "# CUDA toolkit — local-llm-setup"
              echo "export PATH=\"${bin_dir}:\$PATH\""
              echo "export LD_LIBRARY_PATH=\"${lib_dir}:\${LD_LIBRARY_PATH:-}\""
            } >> "$rc"
        fi
    done
    return 0
}

if ! check_command nvcc; then
    info "CUDA toolkit not found — attempting installation via NVIDIA repo."

    UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
    if [[ "$UBUNTU_VERSION" != "22.04" && "$UBUNTU_VERSION" != "24.04" ]]; then
        error "Unsupported Ubuntu version ($UBUNTU_VERSION). Install CUDA manually, then re-run."
    fi

    KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_VERSION//./}/x86_64/cuda-keyring_1.1-1_all.deb"
    info "Downloading CUDA keyring from $KEYRING_URL"
    
    # FIX: Show wget output so we can see why it fails, and fallback to system package if needed
    if ! retry 3 5 wget --verbose -O "$TEMP_DIR/cuda-keyring.deb" "$KEYRING_URL"; then
        warn "Failed to download CUDA keyring after multiple attempts."
        warn "Trying to install CUDA toolkit from system repositories (may be older version)."
        if sudo apt-get install -y nvidia-cuda-toolkit; then
            info "Successfully installed nvidia-cuda-toolkit from system repos."
        else
            error "Could not install CUDA toolkit via system repos either. Please install CUDA manually."
        fi
    else
        sudo dpkg -i "$TEMP_DIR/cuda-keyring.deb" || warn "dpkg reported non-zero for keyring — may be harmless."
        rm -f "$TEMP_DIR/cuda-keyring.deb"
        sudo apt-get update -qq || warn "apt update after adding CUDA repo returned non-zero."

        all_cuda_pkgs=$(apt-cache search --names-only '^cuda-toolkit-[0-9]+-[0-9]+$' 2>/dev/null \
                        | awk '{print $1}')

        CUDA_PKG=$(echo "$all_cuda_pkgs" | grep '^cuda-toolkit-12-' | sort -V | tail -n1 || true)

        if [[ -n "$CUDA_PKG" ]]; then
            info "Installing $CUDA_PKG (CUDA 12.x — best compatibility with llama-cpp-python wheels)…"
            sudo apt-get install -y "$CUDA_PKG" \
                || warn "CUDA package install returned non-zero — may still be usable."
        else
            CUDA_PKG=$(echo "$all_cuda_pkgs" | sort -V | tail -n1 || true)
            if [[ -n "$CUDA_PKG" ]]; then
                warn "No CUDA 12.x toolkit found — installing $CUDA_PKG."
                warn "Pre-built llama-cpp-python wheels may not exist for this version; a source build will be attempted."
                sudo apt-get install -y "$CUDA_PKG" || warn "CUDA package install returned non-zero."
            else
                warn "No versioned cuda-toolkit found; trying cuda-toolkit (latest)."
                sudo apt-get install -y cuda-toolkit || warn "cuda-toolkit install returned non-zero."
            fi
        fi
    fi

    setup_cuda_env || true

    if ! command -v nvcc &>/dev/null; then
        NVCC_PATH=$(find /usr/local -name nvcc -type f 2>/dev/null | head -n1 || true)
        if [[ -n "$NVCC_PATH" ]]; then
            export PATH="$(dirname "$NVCC_PATH"):$PATH"
            info "Found nvcc at $NVCC_PATH — added to PATH."
        else
            warn "nvcc not found after CUDA install. You may need to reboot or check the install."
        fi
    else
        info "CUDA toolkit installed: $(nvcc --version 2>/dev/null | grep release | head -n1 || echo 'version unknown')"
    fi
else
    info "CUDA toolkit already present: $(nvcc --version 2>/dev/null | grep release | head -n1 || echo 'version unknown')"
    setup_cuda_env || true
fi

if ldconfig -p 2>/dev/null | grep -q "libcudart.so.12"; then
    info "libcudart.so.12 found in ldconfig cache."
elif [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    info "libcudart.so.12 not in ldconfig but LD_LIBRARY_PATH is set — should be fine."
else
    warn "libcudart.so.12 not found. If llama-cpp-python fails, re-run and check CUDA install."
fi

# =============================================================================
# PYTHON VIRTUAL ENVIRONMENT
# =============================================================================
step "Python virtual environment"

info "Setting up venv at $VENV_DIR"
if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR" || error "Failed to create Python venv."
fi

source "$VENV_DIR/bin/activate" || error "Failed to activate venv at $VENV_DIR."

if [[ "${VIRTUAL_ENV:-}" != "$VENV_DIR" ]]; then
    error "Venv activation failed (VIRTUAL_ENV='${VIRTUAL_ENV:-}' expected '$VENV_DIR')."
fi
info "Venv active: $VIRTUAL_ENV"

pip install --upgrade pip setuptools wheel --quiet \
    || warn "pip upgrade returned non-zero — likely harmless."

# =============================================================================
# LLAMA-CPP-PYTHON WITH CUDA + AVX2
# =============================================================================
step "llama-cpp-python (CUDA + AVX2)"

SOURCE_BUILD_CMAKE_ARGS="-DGGML_CUDA=ON -DLLAMA_CUBLAS=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DCMAKE_BUILD_TYPE=Release"

detect_cuda_major_minor() {
    local ver=""
    ver=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9]+\.[0-9]+' | head -n1 || true)
    if [[ -z "$ver" ]]; then
        ver=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' | head -n1 || true)
    fi
    echo "${ver:-12.1}"
}

CUDA_VER=$(detect_cuda_major_minor)
CUDA_TAG="cu$(echo "$CUDA_VER" | tr -d '.')"
info "Detected CUDA version: $CUDA_VER → wheel tag: $CUDA_TAG"

WHEEL_URLS=(
    "https://abetlen.github.io/llama-cpp-python/whl/${CUDA_TAG}"
    "https://abetlen.github.io/llama-cpp-python/whl/cu121"
    "https://abetlen.github.io/llama-cpp-python/whl/cu122"
    "https://abetlen.github.io/llama-cpp-python/whl/cu124"
)

LLAMA_INSTALLED=0
for wheel_url in "${WHEEL_URLS[@]}"; do
    info "Trying pre-built wheel from $wheel_url …"
    if pip install llama-cpp-python \
           --index-url "$wheel_url" \
           --extra-index-url https://pypi.org/simple \
           --quiet 2>&1; then
        info "Pre-built CUDA wheel installed from $wheel_url."
        LLAMA_INSTALLED=1
        break
    else
        warn "Wheel from $wheel_url failed — trying next…"
    fi
done

if [[ "$LLAMA_INSTALLED" -eq 0 ]]; then
    warn "All pre-built wheels failed — building from source (takes ~5 min on i7-7700K)…"
    MAKE_JOBS=$HW_THREADS \
    CMAKE_ARGS="$SOURCE_BUILD_CMAKE_ARGS" \
    pip install llama-cpp-python --no-cache-dir \
        || warn "Source build also failed. Check CUDA paths and re-run."
fi

if check_python_module llama_cpp; then
    info "llama-cpp-python import: OK"
else
    warn "llama-cpp-python import failed. Check CUDA library paths."
    warn "  LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<unset>}"
    warn "  Try: source $VENV_DIR/bin/activate && python3 -c 'import llama_cpp'"
fi

# =============================================================================
# OLLAMA
# =============================================================================
step "Ollama"

if ! check_command ollama; then
    info "Installing Ollama…"
    retry 3 10 bash -c "curl -fsSL https://ollama.com/install.sh | sh" </dev/null \
        || error "Ollama installer failed after 3 attempts."
else
    info "Ollama already installed: $(ollama --version 2>/dev/null || echo 'version unknown')"
fi

check_command ollama "Ollama installation failed." || error "Ollama not available after install."

# ---------- Configure Ollama --------------------------------------------------
sudo mkdir -p /etc/ollama
sudo tee /etc/ollama/config.json > /dev/null <<EOF
{
    "disable_telemetry": true,
    "models": "$OLLAMA_MODELS"
}
EOF

if is_wsl2; then
    LAUNCHER="$BIN_DIR/ollama-start"
    cat > "$LAUNCHER" <<LAUNCHER_EOF
#!/usr/bin/env bash
export OLLAMA_MODELS="$OLLAMA_MODELS"
export OLLAMA_HOST="127.0.0.1:11434"
export OLLAMA_NUM_PARALLEL=1
export OLLAMA_MAX_LOADED_MODELS=1
export OLLAMA_NUM_THREAD=$HW_THREADS
if pgrep -f "ollama serve" > /dev/null 2>&1; then
    echo "Ollama already running."
else
    echo "Starting Ollama…"
    nohup ollama serve > "\$HOME/.ollama.log" 2>&1 &
    sleep 3
    pgrep -f "ollama serve" > /dev/null 2>&1 && echo "Ollama started." \
        || echo "WARNING: Ollama may not have started — check ~/.ollama.log"
fi
LAUNCHER_EOF
    chmod +x "$LAUNCHER"
    "$LAUNCHER" || warn "Ollama launcher returned non-zero."
else
    sudo mkdir -p /etc/systemd/system/ollama.service.d
    sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null <<EOF
[Service]
Environment="OLLAMA_MODELS=$OLLAMA_MODELS"
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_NUM_THREAD=$HW_THREADS"
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable ollama  || warn "systemctl enable ollama failed."
    sudo systemctl restart ollama || warn "systemctl restart ollama failed."
fi

sleep 3
if is_wsl2; then
    pgrep -f "ollama serve" >/dev/null 2>&1 && info "Ollama is running." \
        || warn "Ollama not running. Start with: ollama-start"
else
    systemctl is-active --quiet ollama 2>/dev/null && info "Ollama service active." \
        || warn "Ollama service not active. Check: sudo systemctl status ollama"
fi

# =============================================================================
# HELPER SCRIPTS
# =============================================================================
step "Helper scripts"

cat > "$BIN_DIR/run-gguf" <<PYEOF
#!/usr/bin/env python3
import sys, os, glob, argparse

MODEL_DIR  = os.path.expanduser("~/local-llm-models/gguf")
CONFIG_DIR = os.path.expanduser("~/.config/local-llm")
VENV_SITE  = os.path.expanduser("~/.local/share/llm-venv/lib")

import glob as _glob
for _sp in _glob.glob(os.path.join(VENV_SITE, "python3*/site-packages")):
    if _sp not in sys.path:
        sys.path.insert(0, _sp)

HW_THREADS = 8
HW_BATCH   = 512

def list_models():
    models = glob.glob(os.path.join(MODEL_DIR, "*.gguf"))
    if not models:
        print("No GGUF models found in", MODEL_DIR)
        return
    print("Available GGUF models:")
    for m in sorted(models):
        size = os.path.getsize(m) / (1024**3)
        print(f"  {os.path.basename(m):<55} {size:.1f} GB")

def get_default_gpu_layers(model_name: str) -> int:
    cfg = os.path.join(CONFIG_DIR, "selected_model.conf")
    if os.path.exists(cfg):
        with open(cfg) as f:
            for line in f:
                line = line.strip()
                if line.startswith("GPU_LAYERS="):
                    try:
                        return int(line.split("=", 1)[1].strip().strip('"'))
                    except ValueError:
                        pass
    return 35

def main():
    parser = argparse.ArgumentParser(
        description="Run a local GGUF model (tuned for i7-7700K + RTX 3060 12 GB)")
    parser.add_argument("model",  nargs="?",  help="Model filename or full path")
    parser.add_argument("prompt", nargs="*",  help="Prompt text")
    parser.add_argument("--gpu-layers", type=int, default=None,
                        help="GPU layers to offload (default from config or 35)")
    parser.add_argument("--ctx",        type=int, default=$HW_CTX,
                        help="Context window size (default: $HW_CTX)")
    parser.add_argument("--max-tokens", type=int, default=512,
                        help="Max new tokens")
    parser.add_argument("--threads",    type=int, default=HW_THREADS,
                        help=f"CPU threads (default: {HW_THREADS} for i7-7700K)")
    parser.add_argument("--batch",      type=int, default=HW_BATCH,
                        help=f"GPU batch size (default: {HW_BATCH}; lower = less VRAM)")
    args = parser.parse_args()

    if not args.model:
        list_models()
        sys.exit(0)

    model_path = args.model if os.path.isabs(args.model) \
                 else os.path.join(MODEL_DIR, args.model)
    if not os.path.exists(model_path):
        print(f"Model not found: {model_path}")
        list_models()
        sys.exit(1)

    prompt     = " ".join(args.prompt) if args.prompt else "Hello! How are you?"
    gpu_layers = args.gpu_layers if args.gpu_layers is not None \
                 else get_default_gpu_layers(os.path.basename(model_path))

    try:
        from llama_cpp import Llama
        print(
            f"Loading {os.path.basename(model_path)} "
            f"({gpu_layers} GPU layers | {args.threads} CPU threads | "
            f"batch {args.batch} | ctx {args.ctx})…",
            flush=True
        )
        llm = Llama(
            model_path    = model_path,
            n_gpu_layers  = gpu_layers,
            n_threads     = args.threads,
            n_batch       = args.batch,
            verbose       = False,
            n_ctx         = args.ctx,
        )
        output = llm(prompt, max_tokens=args.max_tokens,
                     echo=True, temperature=0.7, top_p=0.95)
        print(output["choices"][0]["text"])
    except ImportError:
        print("ERROR: llama_cpp not found. Activate the venv first:")
        print(f"  source ~/.local/share/llm-venv/bin/activate")
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
PYEOF
chmod +x "$BIN_DIR/run-gguf"

cat > "$BIN_DIR/local-models-info" <<'EOF'
#!/usr/bin/env bash
echo "=== Ollama Models ==="
ollama list 2>/dev/null || echo "  (Ollama not running or no models)"
echo ""
echo "=== GGUF Models ==="
shopt -s nullglob
gguf_files=(~/local-llm-models/gguf/*.gguf)
if [[ ${#gguf_files[@]} -eq 0 ]]; then
    echo "  (none)"
else
    for f in "${gguf_files[@]}"; do
        size=$(du -sh "$f" 2>/dev/null | cut -f1)
        printf "  %-55s %s\n" "$(basename "$f")" "$size"
    done
fi
echo ""
echo "=== Disk Usage ==="
du -sh ~/local-llm-models 2>/dev/null || echo "  (no models dir)"
if [[ -f ~/.config/local-llm/selected_model.conf ]]; then
    echo ""
    echo "=== Selected Model ==="
    source ~/.config/local-llm/selected_model.conf
    echo "  Name:       ${MODEL_NAME:-?}"
    echo "  Size:       ${MODEL_SIZE:-?}"
    echo "  GPU layers: ${GPU_LAYERS:-?}"
    echo "  File:       ${MODEL_FILENAME:-?}"
fi
EOF
chmod +x "$BIN_DIR/local-models-info"
info "Helper scripts written to $BIN_DIR"

# =============================================================================
# SHELL ALIASES
# =============================================================================
step "Shell aliases"

cat > "$ALIAS_FILE" <<'ALIASES_EOF'
# ── Local LLM aliases ────────────────────────────────────────────────────────
alias ollama-list='ollama list'
alias ollama-pull='ollama pull'
alias ollama-run='ollama run'
alias gguf-list='local-models-info'
alias gguf-run='run-gguf'
alias ask='run-gguf'
alias llm-status='local-models-info'

load-model() {
    local cfg=~/.config/local-llm/selected_model.conf
    [[ -f "$cfg" ]] && source "$cfg" \
        && echo "Loaded: $MODEL_NAME — use: run-model \"<prompt>\"" \
        || echo "No model selected — run the setup script and pick a model."
}

run-model() {
    local cfg=~/.config/local-llm/selected_model.conf
    if [[ ! -f "$cfg" ]]; then echo "No model selected."; return 1; fi
    source "$cfg"
    run-gguf "$MODEL_FILENAME" "$@"
}

llm-help() {
    cat <<'HELP'
Available LLM commands (tuned for i7-7700K + RTX 3060 12 GB):
  ollama-list                  List downloaded Ollama models
  ollama-pull <model>          Pull an Ollama model
  ollama-run  <model>          Run an Ollama model interactively
  gguf-list                    List local GGUF models + disk usage
  gguf-run  <file> [prompt]    Run a GGUF model directly
    --gpu-layers N             Override GPU layer count
    --ctx       N              Context window (default 4096)
    --max-tokens N             Max response tokens (default 512)
    --threads   N              CPU threads (default 8, i7-7700K)
    --batch     N              GPU batch size (default 512, 3060 12 GB)
  ask   (alias for gguf-run)
  load-model                   Load saved model config
  run-model [prompt]           Run the currently loaded model
  llm-status                   Show all models and disk usage
  llm-help                     Show this help
HELP
}
ALIASES_EOF

for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f "$rc" ]] && ! grep -q "source $ALIAS_FILE" "$rc"; then
        {
          echo ""
          echo "# Local LLM aliases"
          echo "[ -f $ALIAS_FILE ] && source $ALIAS_FILE"
        } >> "$rc"
        info "Aliases sourced in $rc"
    fi
done

# =============================================================================
# MODEL SELECTION MENU
# =============================================================================
step "Model selection"

if ask_yes_no "Select a model optimised for RTX 3060 12 GB + 16 GB RAM?"; then
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        Select a Model to Download                      ║${NC}"
    echo -e "${BLUE}║  Tuned for RTX 3060 12 GB VRAM + 16 GB RAM             ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}\n"

    echo "  1) Qwen3-8B-abliterated         Q6_K    35+ tok/s    36 layers  ~8.5 GB VRAM  ← best speed"
    echo "  2) Mistral-Nemo-12B             Q5_K_M  30-35 tok/s  40 layers  ~9.0 GB VRAM  ← good balance"
    echo "  3) Qwen2.5-14B-Instruct         Q4_K_M  25-30 tok/s  38 layers  ~10.5 GB VRAM"
    echo "  4) SOLAR-10.7B-Uncensored       Q6_K    28-33 tok/s  40 layers  ~9.5 GB VRAM"
    echo "  5) Mistral-Small-22B            Q4_K_M  15-20 tok/s  26 layers  ~11.5 GB VRAM (partial CPU offload)"
    echo "  6) Wizard-Vicuna-30B-Uncensored Q3_K_S   8-12 tok/s  20 layers  ~10 GB VRAM + ~5 GB RAM ⚠ risky on 16 GB"
    echo "  7) Skip"
    echo ""
    echo -e "  ${YELLOW}Note:${NC} 70B models require 48+ GB RAM — not viable on 16 GB."
    echo ""
    read -r -p "  Enter choice [1-7]: " choice

    NAME="" URL="" FILE="" SIZE="" LAYERS="" MODEL_SKIP=0
    case "$choice" in
        1) NAME="Qwen3-8B-abliterated"
           URL="https://huggingface.co/mradermacher/Qwen3-8B-192k-Context-6X-Josiefied-Uncensored-i1-GGUF/resolve/main/Qwen3-8B-192k-Context-6X-Josiefied-Uncensored-i1.Q6_K.gguf"
           FILE="qwen3-8b-abliterated-q6_k.gguf"; SIZE="8B"; LAYERS=36 ;;
        2) NAME="Mistral-Nemo-12B"
           URL="https://huggingface.co/bartowski/Mistral-Nemo-Instruct-2407-GGUF/resolve/main/Mistral-Nemo-Instruct-2407-Q5_K_M.gguf"
           FILE="mistral-nemo-12b-q5_k_m.gguf"; SIZE="12B"; LAYERS=40 ;;
        3) NAME="Qwen2.5-14B-Instruct"
           URL="https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF/resolve/main/qwen2.5-14b-instruct-q4_k_m.gguf"
           FILE="qwen2.5-14b-instruct-q4_k_m.gguf"; SIZE="14B"; LAYERS=38 ;;
        4) NAME="SOLAR-10.7B-Uncensored"
           URL="https://huggingface.co/mradermacher/SOLAR-10.7B-Instruct-v1.0-uncensored-GGUF/resolve/main/SOLAR-10.7B-Instruct-v1.0-uncensored.Q6_K.gguf"
           FILE="solar-10.7b-q6_k.gguf"; SIZE="11B"; LAYERS=40 ;;
        5) NAME="Mistral-Small-22B"
           URL="https://huggingface.co/bartowski/Mistral-Small-22B-ArliAI-RPMax-v1.1-GGUF/resolve/main/Mistral-Small-22B-ArliAI-RPMax-v1.1-Q4_K_M.gguf"
           FILE="mistral-small-22b-q4_k_m.gguf"; SIZE="22B"; LAYERS=26
           warn "22B model: ~11.5 GB VRAM + ~4 GB RAM. Close to limits on 16 GB." ;;
        6) NAME="Wizard-Vicuna-30B-Uncensored"
           URL="https://huggingface.co/TheBloke/Wizard-Vicuna-30B-Uncensored-GGUF/resolve/main/wizard-vicuna-30b-uncensored.Q3_K_S.gguf"
           FILE="wizard-vicuna-30b-q3_k_s.gguf"; SIZE="30B"; LAYERS=20
           warn "⚠  30B model with 16 GB RAM: expect swap usage and possible OOM."
           warn "   8-10 tok/s at best. If it crashes: lower --gpu-layers to 15." ;;
        7) info "Skipping model selection."; MODEL_SKIP=1 ;;
        *) warn "Invalid choice — skipping model selection."; MODEL_SKIP=1 ;;
    esac

    if [[ "$MODEL_SKIP" -eq 0 && -n "$NAME" ]]; then
        mkdir -p "$CONFIG_DIR"
        cat > "$MODEL_CONFIG" <<EOF
MODEL_NAME="$NAME"
MODEL_URL="$URL"
MODEL_FILENAME="$FILE"
MODEL_SIZE="$SIZE"
GPU_LAYERS="$LAYERS"
EOF
        info "Model config saved: $MODEL_CONFIG"

        if ask_yes_no "Download $NAME now?"; then
            info "Downloading $FILE to $GGUF_MODELS …"
            pushd "$GGUF_MODELS" > /dev/null
            if command -v wget &>/dev/null; then
                # FIX: removed -q to show progress and errors
                retry 3 15 wget --tries=1 --timeout=60 --show-progress -c \
                    "$URL" -O "$FILE" \
                    || warn "Download failed — resume with: wget -c '$URL' -O '$GGUF_MODELS/$FILE'"
            else
                # FIX: removed -# (silent) to show progress
                retry 3 15 curl -L --connect-timeout 30 --retry 0 -C - -o "$FILE" \
                    "$URL" \
                    || warn "Download failed — resume with: curl -L -C - '$URL' -o '$GGUF_MODELS/$FILE'"
            fi
            if [[ -f "$FILE" ]]; then
                info "Download complete: $(du -h "$FILE" | cut -f1)"
            fi
            popd > /dev/null
        fi
    fi
fi

# =============================================================================
# QUALITY-OF-LIFE TOOLS
# =============================================================================
step "Quality-of-life tools"

if ask_yes_no "Install QoL tools (zsh, htop, tmux, tree, ranger, w3m, mousepad, thunar)?"; then
    info "Installing QoL packages…"
    sudo apt-get install -y zsh htop tmux tree ranger w3m w3m-img mousepad thunar \
        || warn "Some QoL packages failed — continuing."

    for tool in zsh htop tmux tree ranger; do
        command -v "$tool" &>/dev/null && info "$tool: OK" || warn "$tool install may have failed."
    done

    if ask_yes_no "Install ezsh (alternative Zsh framework) instead of Oh My Zsh?"; then
        info "Cloning ezsh…"
        if retry 2 5 git clone https://github.com/jotyGill/ezsh "$TEMP_DIR/ezsh"; then
            pushd "$TEMP_DIR/ezsh" > /dev/null
            ./install.sh </dev/null || warn "ezsh install script returned non-zero."
            popd > /dev/null
            rm -rf "$TEMP_DIR/ezsh"
        else
            warn "Failed to clone ezsh."
        fi
    else
        if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
            info "Installing Oh My Zsh…"
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
                "" --unattended </dev/null || warn "Oh My Zsh installer returned non-zero."
        else
            info "Oh My Zsh already installed."
        fi

        ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
        for plugin_repo in \
            "zsh-users/zsh-syntax-highlighting" \
            "zsh-users/zsh-autosuggestions"; do
            plugin_name="${plugin_repo##*/}"
            plugin_dir="$ZSH_CUSTOM/plugins/$plugin_name"
            if [[ ! -d "$plugin_dir" ]]; then
                retry 2 5 git clone "https://github.com/${plugin_repo}.git" "$plugin_dir" \
                    || warn "Failed to clone $plugin_name."
            else
                info "$plugin_name already present."
            fi
        done

        if [[ -f "$HOME/.zshrc" ]]; then
            if ! grep -q "zsh-syntax-highlighting" "$HOME/.zshrc"; then
                sed -i 's/^plugins=(git)/plugins=(git zsh-syntax-highlighting zsh-autosuggestions)/' \
                    "$HOME/.zshrc" 2>/dev/null || true
            fi
        fi

        if ask_yes_no "Install fzf-tab (fuzzy tab completion)?"; then
            fzf_tab_dir="$ZSH_CUSTOM/plugins/fzf-tab"
            if [[ ! -d "$fzf_tab_dir" ]]; then
                retry 2 5 git clone https://github.com/Aloxaf/fzf-tab "$fzf_tab_dir" \
                    || warn "Failed to clone fzf-tab."
            fi
            if ! command -v fzf &>/dev/null; then
                info "Installing fzf…"
                if retry 2 5 git clone --depth 1 https://github.com/junegunn/fzf.git "$TEMP_DIR/fzf"; then
                    "$TEMP_DIR/fzf/install" --all --no-bash --no-fish --no-update-rc || true
                    rm -rf "$TEMP_DIR/fzf"
                else
                    warn "Failed to clone fzf."
                fi
            fi
            if [[ -f "$HOME/.zshrc" ]] && ! grep -q "fzf-tab" "$HOME/.zshrc"; then
                sed -i 's/^plugins=(\(.*\))/plugins=(\1 fzf-tab)/' "$HOME/.zshrc" 2>/dev/null || true
            fi
        fi
    fi

    if [[ -f "$HOME/.zshrc" ]] && ! grep -q "source $ALIAS_FILE" "$HOME/.zshrc"; then
        {
          echo ""
          echo "# Local LLM aliases"
          echo "[ -f $ALIAS_FILE ] && source $ALIAS_FILE"
        } >> "$HOME/.zshrc"
    fi

    ZSH_BIN=$(command -v zsh 2>/dev/null || true)
    if [[ -n "$ZSH_BIN" && "$SHELL" != "$ZSH_BIN" ]]; then
        if ask_yes_no "Set zsh as your default shell?"; then
            chsh -s "$ZSH_BIN" || warn "chsh failed — run manually: chsh -s $ZSH_BIN"
        fi
    fi

    ranger --copy-config=all 2>/dev/null || true
fi

# =============================================================================
# FINAL VALIDATION
# =============================================================================
step "Final validation"

PASS=0; WARN_COUNT=0

if ldconfig -p 2>/dev/null | grep -q "libcudart.so.12" || [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    info "✔ CUDA runtime library reachable."; (( PASS++ )) || true
else
    warn "✘ libcudart.so.12 not found — CUDA may have issues."; (( WARN_COUNT++ )) || true
fi

if check_python_module llama_cpp; then
    info "✔ llama-cpp-python importable."; (( PASS++ )) || true
else
    warn "✘ llama-cpp-python import failed."; (( WARN_COUNT++ )) || true
fi

if is_wsl2; then
    if pgrep -f "ollama serve" >/dev/null 2>&1; then
        info "✔ Ollama running (WSL2)."; (( PASS++ )) || true
    else
        warn "✘ Ollama not running — start with: ollama-start"; (( WARN_COUNT++ )) || true
    fi
else
    if systemctl is-active --quiet ollama 2>/dev/null; then
        info "✔ Ollama service active."; (( PASS++ )) || true
    else
        warn "✘ Ollama service not active — check: sudo systemctl status ollama"; (( WARN_COUNT++ )) || true
    fi
fi

for script in "$BIN_DIR/run-gguf" "$BIN_DIR/local-models-info"; do
    if [[ -x "$script" ]]; then
        info "✔ $(basename "$script") executable."; (( PASS++ )) || true
    else
        warn "✘ $script missing or not executable."; (( WARN_COUNT++ )) || true
    fi
done

if [[ -f "$ALIAS_FILE" ]]; then
    info "✔ Aliases file present."; (( PASS++ )) || true
else
    warn "✘ Aliases file missing."; (( WARN_COUNT++ )) || true
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      ✅  Local LLM Setup Complete!                   ║${NC}"
echo -e "${GREEN}║  i7-7700K + 16 GB RAM + RTX 3060 12 GB              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Checks passed : ${GREEN}$PASS${NC}   Warnings: ${YELLOW}$WARN_COUNT${NC}"
echo ""
echo -e "  Models base   : $MODEL_BASE"
echo -e "  GGUF models   : $GGUF_MODELS"
echo -e "  Ollama models : $OLLAMA_MODELS"
echo -e "  Virtual env   : $VENV_DIR"
echo -e "  Aliases file  : $ALIAS_FILE"
echo -e "  Log file      : $LOG_FILE"
echo ""

if [[ -f "$MODEL_CONFIG" ]]; then
    source "$MODEL_CONFIG"
    echo -e "  ${CYAN}Selected model : ${GREEN}${MODEL_NAME}${NC} (${MODEL_SIZE})"
    echo -e "  File           : ${MODEL_FILENAME}"
    echo -e "  GPU layers     : ${GPU_LAYERS}  (RTX 3060 12 GB tuned)"
    echo -e "  Quick test     : ${YELLOW}run-model \"What is AI?\"${NC}"
    echo ""
fi

echo -e "  ${YELLOW}Hardware tips for your setup:${NC}"
echo -e "    • Context >4096 increases VRAM fast on 3060 — keep default unless needed"
echo -e "    • If llama.cpp OOMs, reduce --gpu-layers by 4 and retry"
echo -e "    • For Ollama: OLLAMA_NUM_PARALLEL=1 is enforced (16 GB RAM limit)"
echo -e "    • CPU layers use AVX2 on your i7-7700K — still decent throughput"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "    • Open a new terminal  (or: source $ALIAS_FILE)"
echo -e "    • Run ${YELLOW}llm-help${NC} to see available commands"
is_wsl2 && echo -e "    • After any reboot run ${YELLOW}ollama-start${NC}"
echo ""
echo -e "  Enjoy your local LLMs on your RTX 3060 12 GB! 🚀"