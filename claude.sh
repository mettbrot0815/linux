#!/usr/bin/env bash
# =============================================================================
# Local LLM Setup Script — Robust Edition
# Targets: Ubuntu 22.04 / 24.04, NVIDIA RTX 3060 12GB (or similar)
# =============================================================================

# ---------- Strict mode (safe version) ----------------------------------------
# We use set -uo but NOT set -e / pipefail globally because:
#   - ask_yes_no returns 1 for "No", which -e would misinterpret as a crash
#   - grep/find pipes legitimately return 1 for "not found"
# Instead we use explicit || handling everywhere it matters.
set -uo pipefail

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
# Set up logging FIRST so every message is captured
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
# Always returns 0 (true) or 1 (false) — never crashes under set -e variants.
ask_yes_no() {
    local prompt="$1" ans=""
    # Non-interactive fallback: default No
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
        (( attempt++ ))
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

info "Starting local LLM setup — log: $LOG_FILE"
is_wsl2 && info "WSL2 environment detected." || info "Native Linux environment detected."

# =============================================================================
# SYSTEM DEPENDENCIES
# =============================================================================
step "System dependencies"

info "Running apt update…"
sudo apt-get update -qq || warn "apt update returned non-zero (may be harmless)."

PKGS=(curl wget git build-essential python3 python3-pip python3-venv lsb-release)
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
    info "GPU: $GPU_NAME | Driver: $DRIVER_VER"
fi

# =============================================================================
# CUDA TOOLKIT
# =============================================================================
step "CUDA toolkit"

setup_cuda_env() {
    # Find libcudart.so.12 anywhere under common CUDA paths
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

    # Derive bin dir (handles /usr/local/cuda-12.x/lib64 → /usr/local/cuda-12.x/bin)
    local base_dir
    base_dir="$(echo "$lib_dir" | sed 's|/lib[^/]*$||')"
    local bin_dir="$base_dir/bin"
    if [[ -d "$bin_dir" ]]; then
        export PATH="$bin_dir:$PATH"
        info "CUDA bin: $bin_dir"
    fi

    # Persist into shell configs (idempotent)
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
    info "CUDA toolkit not found — installing via NVIDIA repo (driver is NOT touched)."

    UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
    if [[ "$UBUNTU_VERSION" != "22.04" && "$UBUNTU_VERSION" != "24.04" ]]; then
        error "Unsupported Ubuntu version ($UBUNTU_VERSION). Install CUDA manually, then re-run."
    fi

    KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_VERSION//./}/x86_64/cuda-keyring_1.1-1_all.deb"
    info "Downloading CUDA keyring from $KEYRING_URL"
    retry 3 5 wget -q -O "$TEMP_DIR/cuda-keyring.deb" "$KEYRING_URL" \
        || error "Failed to download CUDA keyring. Check your internet connection."

    sudo dpkg -i "$TEMP_DIR/cuda-keyring.deb" || warn "dpkg reported non-zero for keyring — may be harmless."
    rm -f "$TEMP_DIR/cuda-keyring.deb"
    sudo apt-get update -qq || warn "apt update after adding CUDA repo returned non-zero."

    # Pick the best CUDA toolkit package.
    # llama-cpp-python pre-built wheels exist for CUDA 12.x (cu121/cu122/cu124).
    # Prefer the latest 12.x; only fall back to a newer major if 12.x is absent.
    all_cuda_pkgs=$(apt-cache search --names-only '^cuda-toolkit-[0-9]+-[0-9]+$' 2>/dev/null \
                    | awk '{print $1}')

    # First choice: highest cuda-toolkit-12-* available
    CUDA_PKG=$(echo "$all_cuda_pkgs" | grep '^cuda-toolkit-12-' | sort -V | tail -n1 || true)

    if [[ -n "$CUDA_PKG" ]]; then
        info "Installing $CUDA_PKG (CUDA 12.x — best compatibility with llama-cpp-python wheels)…"
        sudo apt-get install -y "$CUDA_PKG" \
            || warn "CUDA package install returned non-zero — may still be usable."
    else
        # No 12.x found — warn loudly, then try whatever is newest
        CUDA_PKG=$(echo "$all_cuda_pkgs" | sort -V | tail -n1 || true)
        if [[ -n "$CUDA_PKG" ]]; then
            warn "No CUDA 12.x toolkit found — installing $CUDA_PKG."
            warn "Pre-built llama-cpp-python wheels may not exist for this version; a source build will be attempted."
            sudo apt-get install -y "$CUDA_PKG" \
                || warn "CUDA package install returned non-zero."
        else
            warn "No versioned cuda-toolkit found; trying cuda-toolkit (latest)."
            sudo apt-get install -y cuda-toolkit \
                || warn "cuda-toolkit install returned non-zero."
        fi
    fi

    # Configure env BEFORE checking nvcc
    setup_cuda_env || true

    # Verify nvcc is now available
    if ! command -v nvcc &>/dev/null; then
        # Last-ditch: find nvcc in the filesystem
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

# Friendly CUDA library check (non-fatal)
if ldconfig -p 2>/dev/null | grep -q "libcudart.so.12"; then
    info "libcudart.so.12 found in ldconfig cache."
elif [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    info "libcudart.so.12 not in ldconfig but LD_LIBRARY_PATH is set — should be fine."
else
    warn "libcudart.so.12 not found in ldconfig. If llama-cpp-python fails, re-run and check CUDA install."
fi

# =============================================================================
# PYTHON VIRTUAL ENVIRONMENT
# =============================================================================
step "Python virtual environment"

info "Setting up venv at $VENV_DIR"
if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR" || error "Failed to create Python venv."
fi

# Activate for the rest of this script
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate" || error "Failed to activate venv at $VENV_DIR."

if [[ "${VIRTUAL_ENV:-}" != "$VENV_DIR" ]]; then
    error "Venv activation failed (VIRTUAL_ENV='${VIRTUAL_ENV:-}' expected '$VENV_DIR')."
fi
info "Venv active: $VIRTUAL_ENV"

pip install --upgrade pip setuptools wheel --quiet \
    || warn "pip upgrade returned non-zero — likely harmless."

# =============================================================================
# LLAMA-CPP-PYTHON WITH CUDA
# =============================================================================
step "llama-cpp-python (CUDA)"

# Detect CUDA version to pick the right wheel index
detect_cuda_major_minor() {
    local ver=""
    # Try nvcc first
    ver=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9]+\.[0-9]+' | head -n1 || true)
    if [[ -z "$ver" ]]; then
        # Try nvidia-smi
        ver=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[0-9]+\.[0-9]+' | head -n1 || true)
    fi
    echo "${ver:-12.1}"  # default to 12.1 if we can't detect
}

CUDA_VER=$(detect_cuda_major_minor)
CUDA_TAG="cu$(echo "$CUDA_VER" | tr -d '.')"   # e.g. cu121, cu122, cu124
info "Detected CUDA version: $CUDA_VER → wheel tag: $CUDA_TAG"

WHEEL_URLS=(
    "https://abetlen.github.io/llama-cpp-python/whl/${CUDA_TAG}"
    "https://abetlen.github.io/llama-cpp-python/whl/cu121"   # safe fallback
    "https://abetlen.github.io/llama-cpp-python/whl/cu122"
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
    warn "All pre-built wheels failed — building from source (takes a few minutes)…"
    CMAKE_ARGS="-DLLAMA_CUBLAS=on" pip install llama-cpp-python --no-cache-dir \
        || warn "Source build also failed. You can retry manually after fixing CUDA paths."
fi

# Verify import (non-fatal — the rest of the setup can still proceed)
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
    retry 3 10 bash -c "curl -fsSL https://ollama.com/install.sh | sh" \
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
if pgrep -f "ollama serve" > /dev/null 2>&1; then
    echo "Ollama already running."
else
    echo "Starting Ollama…"
    nohup ollama serve > "\$HOME/.ollama.log" 2>&1 &
    sleep 3
    pgrep -f "ollama serve" > /dev/null 2>&1 && echo "Ollama started." || echo "WARNING: Ollama may not have started — check ~/.ollama.log"
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
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable ollama  || warn "systemctl enable ollama failed."
    sudo systemctl restart ollama || warn "systemctl restart ollama failed."
fi

# Give Ollama a moment to start
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

cat > "$BIN_DIR/run-gguf" <<'PYEOF'
#!/usr/bin/env python3
"""Run a local GGUF model with llama-cpp-python."""
import sys, os, glob, argparse

MODEL_DIR  = os.path.expanduser("~/local-llm-models/gguf")
CONFIG_DIR = os.path.expanduser("~/.config/local-llm")
VENV_SITE  = os.path.expanduser("~/.local/share/llm-venv/lib")

# Inject venv site-packages so this script works outside the venv
import glob as _glob
for _sp in _glob.glob(os.path.join(VENV_SITE, "python3*/site-packages")):
    if _sp not in sys.path:
        sys.path.insert(0, _sp)

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
    return 35  # safe default for 12 GB VRAM

def main():
    parser = argparse.ArgumentParser(description="Run a local GGUF model")
    parser.add_argument("model",  nargs="?",  help="Model filename or full path")
    parser.add_argument("prompt", nargs="*",  help="Prompt text")
    parser.add_argument("--gpu-layers", type=int, default=None, help="GPU layers to offload")
    parser.add_argument("--ctx",        type=int, default=4096, help="Context window size")
    parser.add_argument("--max-tokens", type=int, default=512,  help="Max new tokens")
    args = parser.parse_args()

    if not args.model:
        list_models()
        sys.exit(0)

    model_path = args.model if os.path.isabs(args.model) else os.path.join(MODEL_DIR, args.model)
    if not os.path.exists(model_path):
        print(f"Model not found: {model_path}")
        list_models()
        sys.exit(1)

    prompt     = " ".join(args.prompt) if args.prompt else "Hello! How are you?"
    gpu_layers = args.gpu_layers if args.gpu_layers is not None \
                 else get_default_gpu_layers(os.path.basename(model_path))

    try:
        from llama_cpp import Llama
        print(f"Loading {os.path.basename(model_path)} ({gpu_layers} GPU layers)…", flush=True)
        llm    = Llama(model_path=model_path, n_gpu_layers=gpu_layers,
                       verbose=False, n_ctx=args.ctx)
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
    # shellcheck source=/dev/null
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
Available LLM commands:
  ollama-list                  List downloaded Ollama models
  ollama-pull <model>          Pull an Ollama model
  ollama-run  <model>          Run an Ollama model interactively
  gguf-list                    List local GGUF models + disk usage
  gguf-run  <file> [prompt]    Run a GGUF model directly
    --gpu-layers N             Override GPU layer count
    --ctx N                    Context window (default 4096)
    --max-tokens N             Max response tokens (default 512)
  ask   (alias for gguf-run)
  load-model                   Load saved model config
  run-model [prompt]           Run the currently loaded model
  llm-status                   Show all models and disk usage
  llm-help                     Show this help
HELP
}
# ─────────────────────────────────────────────────────────────────────────────
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

if ask_yes_no "Select an uncensored model optimised for RTX 3060 12 GB?"; then
    echo -e "\n${BLUE}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           Select a Model to Download             ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════╝${NC}\n"
    echo "  1) Qwen2.5-14B-Instruct      (Q4_K_M) — 25-30 tok/s"
    echo "  2) Mistral-Small-22B         (Q4_K_M) — 15-20 tok/s"
    echo "  3) Mistral-Nemo-12B          (Q5_K_M) — 30-35 tok/s"
    echo "  4) SOLAR-10.7B-Uncensored    (Q6_K)   — 30   tok/s"
    echo "  5) Wizard-Vicuna-30B-Uncensored (Q3_K_S)* — 8-12 tok/s (CPU offload)"
    echo "  6) Qwen3-8B-abliterated      (Q6_K)   — 35+  tok/s"
    echo "  7) Midnight-Miqu-70B         (Q4_K_M)† — needs 64 GB RAM"
    echo "  8) Skip"
    echo ""
    read -r -p "  Enter choice [1-8]: " choice

    NAME="" URL="" FILE="" SIZE="" LAYERS="" MODEL_SKIP=0
    case "$choice" in
        1) NAME="Qwen2.5-14B-Instruct"
           URL="https://huggingface.co/Qwen/Qwen2.5-14B-Instruct-GGUF/resolve/main/qwen2.5-14b-instruct-q4_k_m.gguf"
           FILE="qwen2.5-14b-instruct-q4_k_m.gguf"; SIZE="14B"; LAYERS=35 ;;
        2) NAME="Mistral-Small-22B"
           URL="https://huggingface.co/bartowski/Mistral-Small-22B-ArliAI-RPMax-v1.1-GGUF/resolve/main/Mistral-Small-22B-ArliAI-RPMax-v1.1-Q4_K_M.gguf"
           FILE="mistral-small-22b-q4_k_m.gguf"; SIZE="22B"; LAYERS=35 ;;
        3) NAME="Mistral-Nemo-12B"
           URL="https://huggingface.co/bartowski/Mistral-Nemo-Instruct-2407-GGUF/resolve/main/Mistral-Nemo-Instruct-2407-Q5_K_M.gguf"
           FILE="mistral-nemo-12b-q5_k_m.gguf"; SIZE="12B"; LAYERS=40 ;;
        4) NAME="SOLAR-10.7B-Uncensored"
           URL="https://huggingface.co/mradermacher/SOLAR-10.7B-Instruct-v1.0-uncensored-GGUF/resolve/main/SOLAR-10.7B-Instruct-v1.0-uncensored.Q6_K.gguf"
           FILE="solar-10.7b-q6_k.gguf"; SIZE="11B"; LAYERS=48 ;;
        5) NAME="Wizard-Vicuna-30B-Uncensored"
           URL="https://huggingface.co/TheBloke/Wizard-Vicuna-30B-Uncensored-GGUF/resolve/main/wizard-vicuna-30b-uncensored.Q3_K_S.gguf"
           FILE="wizard-vicuna-30b-q3_k_s.gguf"; SIZE="30B"; LAYERS=25
           warn "30B model — expect 8-12 tok/s with CPU offload." ;;
        6) NAME="Qwen3-8B-abliterated"
           URL="https://huggingface.co/mradermacher/Qwen3-8B-192k-Context-6X-Josiefied-Uncensored-i1-GGUF/resolve/main/Qwen3-8B-192k-Context-6X-Josiefied-Uncensored-i1.Q6_K.gguf"
           FILE="qwen3-8b-abliterated-q6_k.gguf"; SIZE="8B"; LAYERS=36 ;;
        7) NAME="Midnight-Miqu-70B"
           URL="https://huggingface.co/bartowski/Midnight-Miqu-70B-v1.5-GGUF/resolve/main/Midnight-Miqu-70B-v1.5.Q4_K_M.gguf"
           FILE="midnight-miqu-70b-q4_k_m.gguf"; SIZE="70B"; LAYERS=15
           warn "70B requires 48 GB+ RAM — expect low speed." ;;
        8) info "Skipping model selection."; MODEL_SKIP=1 ;;
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
                retry 3 15 wget --tries=1 --timeout=60 -q --show-progress \
                    "$URL" -O "$FILE" \
                    || warn "Download failed — you can retry: wget -c '$URL' -O '$GGUF_MODELS/$FILE'"
            else
                retry 3 15 curl -L --connect-timeout 30 --retry 0 -# \
                    "$URL" -o "$FILE" \
                    || warn "Download failed — you can retry: curl -L -C - '$URL' -o '$GGUF_MODELS/$FILE'"
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

    # ── Zsh framework ───────────────────────────────────────────────────────
    if ask_yes_no "Install ezsh (alternative Zsh framework) instead of Oh My Zsh?"; then
        info "Cloning ezsh…"
        if retry 2 5 git clone https://github.com/jotyGill/ezsh "$TEMP_DIR/ezsh"; then
            pushd "$TEMP_DIR/ezsh" > /dev/null
            ./install.sh || warn "ezsh install script returned non-zero."
            popd > /dev/null
            rm -rf "$TEMP_DIR/ezsh"
        else
            warn "Failed to clone ezsh."
        fi
    else
        if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
            info "Installing Oh My Zsh…"
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
                "" --unattended || warn "Oh My Zsh installer returned non-zero."
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

        # Update .zshrc plugins line (idempotent)
        if [[ -f "$HOME/.zshrc" ]]; then
            if ! grep -q "zsh-syntax-highlighting" "$HOME/.zshrc"; then
                sed -i 's/^plugins=(git)/plugins=(git zsh-syntax-highlighting zsh-autosuggestions)/' \
                    "$HOME/.zshrc" 2>/dev/null || true
            fi
        fi

        # Optional fzf-tab
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

    # Source aliases in .zshrc too
    if [[ -f "$HOME/.zshrc" ]] && ! grep -q "source $ALIAS_FILE" "$HOME/.zshrc"; then
        {
          echo ""
          echo "# Local LLM aliases"
          echo "[ -f $ALIAS_FILE ] && source $ALIAS_FILE"
        } >> "$HOME/.zshrc"
    fi

    # Optionally set zsh as default shell
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

PASS=0; WARN=0

# 1. CUDA libs
if ldconfig -p 2>/dev/null | grep -q "libcudart.so.12" || [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    info "✔ CUDA runtime library reachable."; (( PASS++ ))
else
    warn "✘ libcudart.so.12 not found — CUDA may have issues."; (( WARN++ ))
fi

# 2. llama-cpp-python
if check_python_module llama_cpp; then
    info "✔ llama-cpp-python importable."; (( PASS++ ))
else
    warn "✘ llama-cpp-python import failed."; (( WARN++ ))
fi

# 3. Ollama
if is_wsl2; then
    if pgrep -f "ollama serve" >/dev/null 2>&1; then
        info "✔ Ollama running (WSL2)."; (( PASS++ ))
    else
        warn "✘ Ollama not running — start with: ollama-start"; (( WARN++ ))
    fi
else
    if systemctl is-active --quiet ollama 2>/dev/null; then
        info "✔ Ollama service active."; (( PASS++ ))
    else
        warn "✘ Ollama service not active — check: sudo systemctl status ollama"; (( WARN++ ))
    fi
fi

# 4. Helper scripts
for script in "$BIN_DIR/run-gguf" "$BIN_DIR/local-models-info"; do
    if [[ -x "$script" ]]; then
        info "✔ $(basename "$script") executable."; (( PASS++ ))
    else
        warn "✘ $script missing or not executable."; (( WARN++ ))
    fi
done

# 5. Aliases file
if [[ -f "$ALIAS_FILE" ]]; then
    info "✔ Aliases file present."; (( PASS++ ))
else
    warn "✘ Aliases file missing."; (( WARN++ ))
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        ✅  Local LLM Setup Complete!             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Checks passed : ${GREEN}$PASS${NC}   Warnings: ${YELLOW}$WARN${NC}"
echo ""
echo -e "  Models base   : $MODEL_BASE"
echo -e "  GGUF models   : $GGUF_MODELS"
echo -e "  Ollama models : $OLLAMA_MODELS"
echo -e "  Virtual env   : $VENV_DIR"
echo -e "  Aliases file  : $ALIAS_FILE"
echo -e "  Log file      : $LOG_FILE"
echo ""

if [[ -f "$MODEL_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$MODEL_CONFIG"
    echo -e "  ${CYAN}Selected model : ${GREEN}${MODEL_NAME}${NC} (${MODEL_SIZE})"
    echo -e "  File           : ${MODEL_FILENAME}"
    echo -e "  GPU layers     : ${GPU_LAYERS}"
    echo -e "  Quick test     : ${YELLOW}run-model \"What is AI?\"${NC}"
    echo ""
fi

echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "    • Open a new terminal  (or: source $ALIAS_FILE)"
echo -e "    • Run ${YELLOW}llm-help${NC} to see available commands"
is_wsl2 && echo -e "    • After any reboot run ${YELLOW}ollama-start${NC}"
echo ""
echo -e "  Enjoy your uncensored local LLMs on your RTX 3060 12 GB! 🚀"