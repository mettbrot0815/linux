#!/usr/bin/env bash
# =============================================================================
# Local LLM Setup Script — Optimised for i7-7700K + 16 GB RAM + RTX 3060 12 GB
# Targets: Ubuntu 22.04 / 24.04
# =============================================================================

# ---------- Strict mode -------------------------------------------------------
# Intentionally NO set -e / -E / pipefail globally:
#   - ask_yes_no returns 1 for "No" which -e would misinterpret as a crash
#   - grep/find/arithmetic pipelines legitimately return 1 for "not found" / zero
# We use explicit ||/&& handling for every command that matters.
set -uo pipefail

# =============================================================================
# HARDWARE PROFILE — i7-7700K + 16 GB RAM + RTX 3060 12 GB
# =============================================================================
# CPU: Intel Core i7-7700K (Kaby Lake) — 4 cores / 8 threads, AVX2, no AVX-512
# RAM: 16 GB  → ~13 GB usable for models after OS overhead
# GPU: RTX 3060 12 GB VRAM
#
# Implications tuned below:
#   HW_THREADS=8        — llama.cpp CPU thread count
#   HW_BATCH=512        — GPU batch; 3060 handles 512 well; lower → less VRAM
#   HW_CTX=4096         — safe default context; large ctx costs VRAM
#   HW_GPU_VRAM_GB=12   — used for dynamic layer calculation guard
#   HW_SYS_RAM_GB=16    — cap CPU-offloaded layers accordingly
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

# ---------- HuggingFace token (optional) --------------------------------------
# Required for gated/private models (e.g. Llama 3, Gemma).
# Set before running:  export HF_TOKEN="hf_..."
# Or drop it in ~/.hf_token and this script will pick it up automatically.
if [[ -z "${HF_TOKEN:-}" && -f "$HOME/.hf_token" ]]; then
    HF_TOKEN=$(cat "$HOME/.hf_token")
fi
HF_TOKEN="${HF_TOKEN:-}"   # empty string if not set — no auth header added

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
# FIX: original used (( attempt++ )) which exits under arithmetic traps when
# the result is 0 (i.e. attempt was 0 before increment). Use explicit
# assignment instead.
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
        attempt=$(( attempt + 1 ))   # FIX: safe arithmetic increment
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
info "Hardware profile: i7-7700K (${HW_THREADS}t / AVX2) | ${HW_SYS_RAM_GB}GB RAM | RTX 3060 ${HW_GPU_VRAM_GB}GB VRAM"
is_wsl2 && info "WSL2 environment detected." || info "Native Linux environment detected."

# =============================================================================
# SYSTEM DEPENDENCIES
# =============================================================================
step "System dependencies"

info "Running apt update…"
sudo apt-get update -qq || warn "apt update returned non-zero (may be harmless)."

# FIX: added cmake + ninja — required for llama-cpp-python source builds.
#      libopenblas-dev speeds up CPU inference on Kaby Lake when layers are
#      offloaded to RAM (AVX2 path).
PKGS=(
    curl wget git
    build-essential cmake ninja-build
    python3 python3-pip python3-venv
    lsb-release
    libopenblas-dev        # accelerates CPU tensor ops via AVX2
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

# Ensure $BIN_DIR (~/.local/bin) is on PATH in both shell configs.
# Ubuntu adds it only for login shells via /etc/profile.d; non-login interactive
# shells (the normal case when opening a terminal) often miss it, so run-gguf
# and local-models-info would be unreachable after install.
for _rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [[ -f "$_rc" ]] && ! grep -q "# local-llm-setup PATH" "$_rc"; then
        {
          echo ""
          echo "# local-llm-setup PATH"
          echo "[[ \":\$PATH:\" != *\":$BIN_DIR:\"* ]] && export PATH=\"$BIN_DIR:\$PATH\""
        } >> "$_rc"
        info "Added $BIN_DIR to PATH in $_rc"
    fi
done
# Patch the current session too so later steps can find the installed scripts.
[[ ":$PATH:" != *":$BIN_DIR:"* ]] && export PATH="$BIN_DIR:$PATH"

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

    # Sanity-check VRAM. RTX 3060 reports ~12288 MiB; warn if it's much less.
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

# ---------- CUDA presence check -----------------------------------------------
# Three independent probes — any one passing means CUDA is already installed.
# Only if all three fail do we actually download and install.
#
# Probe A — filesystem scan for nvcc (catches installs outside $PATH)
# Probe B — filesystem scan for libcudart.so.12 (catches libs-only installs)
# Probe C — dpkg (catches any apt-installed cuda package even if its bin dir
#           was never added to PATH, e.g. after a fresh reboot)

CUDA_ALREADY_PRESENT=0

# Probe A: find nvcc anywhere under common install roots and patch PATH.
if ! command -v nvcc &>/dev/null; then
    NVCC_PATH=$(find /usr/local /usr/lib/cuda /opt/cuda -maxdepth 6 \
                    -name nvcc -type f 2>/dev/null | head -n1 || true)
    if [[ -n "$NVCC_PATH" ]]; then
        export PATH="$(dirname "$NVCC_PATH"):$PATH"
        info "nvcc found at $NVCC_PATH — added to PATH."
    fi
fi
command -v nvcc &>/dev/null && CUDA_ALREADY_PRESENT=1

# Probe B: libcudart.so.12 — present means CUDA runtime is installed.
if [[ "$CUDA_ALREADY_PRESENT" -eq 0 ]]; then
    if find /usr/local /usr/lib /opt -maxdepth 7 \
            -name "libcudart.so.12" 2>/dev/null | grep -q .; then
        CUDA_ALREADY_PRESENT=1
        info "libcudart.so.12 found on disk — CUDA runtime already present."
    fi
fi

# Probe C: dpkg — any installed cuda-toolkit-* or cuda-libraries-* package.
if [[ "$CUDA_ALREADY_PRESENT" -eq 0 ]]; then
    if dpkg -l 'cuda-toolkit-*' 'cuda-libraries-*' 2>/dev/null \
            | grep -q '^ii'; then
        CUDA_ALREADY_PRESENT=1
        info "CUDA package found via dpkg — already installed."
    fi
fi

if [[ "$CUDA_ALREADY_PRESENT" -eq 0 ]]; then
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
            warn "Pre-built llama-cpp-python wheels may not exist; a source build will be attempted."
            sudo apt-get install -y "$CUDA_PKG" || warn "CUDA package install returned non-zero."
        else
            warn "No versioned cuda-toolkit found; trying cuda-toolkit (latest)."
            sudo apt-get install -y cuda-toolkit || warn "cuda-toolkit install returned non-zero."
        fi
    fi

    # After install, re-probe for nvcc in case it landed outside PATH.
    if ! command -v nvcc &>/dev/null; then
        NVCC_PATH=$(find /usr/local -name nvcc -type f 2>/dev/null | head -n1 || true)
        if [[ -n "$NVCC_PATH" ]]; then
            export PATH="$(dirname "$NVCC_PATH"):$PATH"
            info "Found nvcc at $NVCC_PATH — added to PATH."
        else
            warn "nvcc not found after CUDA install. You may need to reboot or check the install."
        fi
    fi
else
    info "CUDA toolkit already present: $(nvcc --version 2>/dev/null | grep release | head -n1 || echo 'version unknown')"
fi

# Always run env setup so LD_LIBRARY_PATH and PATH are correct for this session.
setup_cuda_env || true

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

# shellcheck source=/dev/null
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

# FIX: Original CMAKE_ARGS only set LLAMA_CUBLAS. For the i7-7700K (Kaby Lake)
# we also enable:
#   GGML_AVX2=ON      — uses AVX2 SIMD for CPU-side tensor ops (big win for
#                        layers that overflow to RAM with large models)
#   GGML_FMA=ON       — fused multiply-add, pairs well with AVX2 on Kaby Lake
#   GGML_CUDA=ON      — modern cmake flag (replaces LLAMA_CUBLAS in newer builds)
#   LLAMA_CUBLAS=ON   — kept for compatibility with older source trees
#   CMAKE_BUILD_TYPE=Release — ensures compiler optimisations are applied
#
# These flags have NO effect on pre-built wheels (which are already compiled
# with the right flags) — they only apply when falling back to a source build.
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
    "https://abetlen.github.io/llama-cpp-python/whl/cu124"  # FIX: added cu124 fallback
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
    # FIX: use the hardware-tuned CMAKE_ARGS, and set MAKE_JOBS to all 8
    # threads so the source build finishes in ~3–4 min instead of ~10 min.
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
    # FIX: redirect </dev/null so the install.sh pipe-to-sh cannot read from
    # the terminal's stdin. Without this, the sh process silently drains the
    # input stream and every ask_yes_no() call afterwards gets an empty read,
    # causing all prompts (including QoL tools) to be auto-answered "No".
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
# FIX: set per-request thread count so Ollama doesn't over-subscribe the 8
# logical cores on the i7-7700K when doing CPU-offloaded layers.
export OLLAMA_MODELS="$OLLAMA_MODELS"
export OLLAMA_HOST="127.0.0.1:11434"
export OLLAMA_NUM_PARALLEL=1        # only 16 GB RAM — one request at a time
export OLLAMA_MAX_LOADED_MODELS=1   # prevent VRAM thrash from model swapping
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
    # FIX: added OLLAMA_NUM_PARALLEL and OLLAMA_MAX_LOADED_MODELS for 16 GB RAM;
    #      OLLAMA_NUM_THREAD pins Ollama to the 8 logical cores of the i7-7700K.
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

# FIX: run-gguf now passes hardware-tuned defaults:
#   n_threads  = 8   (i7-7700K logical cores)
#   n_batch    = 512 (GPU batch; suits 3060 12 GB, controls VRAM used per
#                     forward pass; lower values reduce VRAM but slow throughput)
# Users can still override everything via CLI flags.
cat > "$BIN_DIR/run-gguf" <<PYEOF
#!/usr/bin/env python3
"""Run a local GGUF model with llama-cpp-python.
Defaults tuned for i7-7700K (8 threads / AVX2) + RTX 3060 12 GB.
"""
import sys, os, glob, argparse

MODEL_DIR  = os.path.expanduser("~/local-llm-models/gguf")
CONFIG_DIR = os.path.expanduser("~/.config/local-llm")
VENV_SITE  = os.path.expanduser("~/.local/share/llm-venv/lib")

# Inject venv site-packages so this script works outside the venv
import glob as _glob
for _sp in _glob.glob(os.path.join(VENV_SITE, "python3*/site-packages")):
    if _sp not in sys.path:
        sys.path.insert(0, _sp)

# Hardware constants
HW_THREADS = 8    # i7-7700K logical cores
HW_BATCH   = 512  # safe for RTX 3060 12 GB; drop to 256 if you see OOM

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
    return 35  # safe default for RTX 3060 12 GB

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
    # FIX: expose n_threads and n_batch so users can tune without editing code
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
            n_threads     = args.threads,   # FIX: was missing — defaults to 4 internally
            n_batch       = args.batch,     # FIX: was missing — GPU prompt batch size
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
alias chat='llm-chat'
alias webui='llm-web'

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
  chat  / llm-chat             Open standalone HTML chat UI in browser
  webui / llm-web              Start Open WebUI at http://localhost:8080
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
# FIX (major): GPU layer counts and model availability re-tuned for
# RTX 3060 12 GB VRAM + 16 GB system RAM.
#
# How GPU layers were calculated:
#   RTX 3060 has 12 GB VRAM. Each transformer layer needs roughly:
#     (hidden_dim * 4 * bytes_per_weight * num_heads_factor) ≈
#     ~80–100 MB/layer for Q4 7B/8B models
#     ~120–150 MB/layer for Q4 13B/14B models
#     ~200–250 MB/layer for Q4 22B models
#   We leave ~1.5 GB headroom for the KV-cache + activations.
#
#   i7-7700K RAM budget for CPU-offloaded layers:
#     16 GB total − ~3 GB OS/kernel − ~1 GB Python − model layers in VRAM
#     Realistically: 5–7 GB free for CPU layers ≈ 4–8 CPU layers on big models.
#
# REMOVED: Midnight-Miqu-70B (needs 48 GB RAM minimum — impossible on 16 GB)
# DEMOTED: Wizard-Vicuna-30B Q3_K_S (~13 GB file) — fits VRAM+RAM barely
#          but leaves almost nothing for the OS; marked as "risky".
# =============================================================================
step "Hugging Face authentication"

HF_TOKEN_FILE="$CONFIG_DIR/hf_token"
HF_TOKEN=""

# Load existing saved token
if [[ -f "$HF_TOKEN_FILE" ]]; then
    HF_TOKEN=$(cat "$HF_TOKEN_FILE")
    info "Hugging Face token loaded from $HF_TOKEN_FILE"
fi

# Prompt for a new/updated token if none saved or user wants to update
if [[ -z "$HF_TOKEN" ]]; then
    echo -e "\n${YELLOW}A Hugging Face token is required to download gated models.${NC}"
    echo -e "  Get one at: ${CYAN}https://huggingface.co/settings/tokens${NC} (role: Read)"
    echo -e "  Leave blank to skip authenticated downloads (public models still work).\n"
fi

if [[ -z "$HF_TOKEN" ]] || ask_yes_no "Update saved Hugging Face token?"; then
    # -s = silent (no echo), so the token never appears on screen or in the log
    read -r -s -p "$(echo -e "${YELLOW}?${NC} Paste your HF token (input hidden): ")" HF_TOKEN_INPUT
    echo  # newline after silent read
    if [[ -n "$HF_TOKEN_INPUT" ]]; then
        # Basic sanity check — HF tokens start with hf_
        if [[ "$HF_TOKEN_INPUT" != hf_* ]]; then
            warn "Token doesn't look like a valid HF token (expected hf_…) — saving anyway."
        fi
        HF_TOKEN="$HF_TOKEN_INPUT"
        # Store with strict permissions — only owner can read
        printf '%s' "$HF_TOKEN" > "$HF_TOKEN_FILE"
        chmod 600 "$HF_TOKEN_FILE"
        info "Token saved to $HF_TOKEN_FILE (chmod 600)"
    else
        warn "No token entered — gated model downloads may fail with HTTP 401."
    fi
fi

# =============================================================================
# MODEL SELECTION MENU
# =============================================================================
step "Model selection"

if ask_yes_no "Select a model optimised for RTX 3060 12 GB + 16 GB RAM?"; then
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        Select a Model to Download                      ║${NC}"
    echo -e "${BLUE}║  Tuned for RTX 3060 12 GB VRAM + 16 GB RAM             ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}\n"

    # Columns:  #  Name                          Quant   Speed        GPU layers  VRAM est
    echo "  1) Dolphin3.0-Llama3.1-8B      Q6_K    35+ tok/s    36 layers  ~8.5 GB VRAM  ← best speed / uncensored"
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
        1) NAME="Dolphin3.0-Llama3.1-8B-Uncensored"
           URL="https://huggingface.co/bartowski/Dolphin3.0-Llama3.1-8B-GGUF/resolve/main/Dolphin3.0-Llama3.1-8B-Q6_K.gguf"
           FILE="dolphin3.0-llama3.1-8b-q6_k.gguf"; SIZE="8B"; LAYERS=36 ;;
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
           # FIX: original had LAYERS=35 which would push ~13 GB into VRAM on a
           # 22B Q4_K_M model (~0.5 GB/layer) — that's an OOM. 26 layers ≈ 11 GB.
           # Remaining ~14 layers offload to CPU/RAM (~4 GB — fits in 16 GB).
           warn "22B model: ~11.5 GB VRAM + ~4 GB RAM. Close to limits on 16 GB." ;;
        6) NAME="Wizard-Vicuna-30B-Uncensored"
           URL="https://huggingface.co/TheBloke/Wizard-Vicuna-30B-Uncensored-GGUF/resolve/main/wizard-vicuna-30b-uncensored.Q3_K_S.gguf"
           FILE="wizard-vicuna-30b-q3_k_s.gguf"; SIZE="30B"; LAYERS=20
           # FIX: original had LAYERS=25 — too high. At ~0.5 GB/layer for Q3_K_S
           # 30B, 20 layers ≈ 10 GB VRAM, remaining 20 layers ≈ 5 GB RAM.
           # Total: 10 GB VRAM + 5 GB RAM + 3 GB OS = 18 GB → will use swap.
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

            # Build auth header if token is available
            HF_AUTH_CURL=()
            HF_AUTH_WGET=()
            if [[ -n "$HF_TOKEN" ]]; then
                HF_AUTH_CURL=(-H "Authorization: Bearer $HF_TOKEN")
                HF_AUTH_WGET=(--header="Authorization: Bearer $HF_TOKEN")
                info "Downloading with Hugging Face authentication."
            else
                warn "No HF token — attempting unauthenticated download (may fail on gated models)."
            fi

            DL_OK=0
            if command -v curl &>/dev/null; then
                retry 3 15 curl -L --fail -C - --progress-bar \
                    "${HF_AUTH_CURL[@]}" \
                    -o "$FILE" "$URL" \
                    && DL_OK=1 \
                    || warn "curl download failed."
            fi

            if [[ "$DL_OK" -eq 0 ]] && command -v wget &>/dev/null; then
                warn "Trying wget fallback…"
                retry 3 15 wget --tries=1 --show-progress \
                    "${HF_AUTH_WGET[@]}" \
                    -c -O "$FILE" "$URL" \
                    && DL_OK=1 \
                    || warn "wget download also failed."
            fi

            if [[ "$DL_OK" -eq 1 && -f "$FILE" ]]; then
                info "Download complete: $(du -h "$FILE" | cut -f1)"
            else
                warn "Download failed after all attempts."
                warn "  Resume manually with:"
                warn "    curl -L -C - -H 'Authorization: Bearer \$(cat $HF_TOKEN_FILE)' -o '$GGUF_MODELS/$FILE' '$URL'"
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
            # FIX: </dev/null prevents Oh My Zsh installer from reading the
            # terminal stdin (some versions still prompt despite --unattended),
            # which would otherwise break all subsequent ask_yes_no calls.
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
                    "$TEMP_DIR/fzf/install" --all --no-bash --no-fish --no-update-rc </dev/null || true
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

    ranger --copy-config=all </dev/null 2>/dev/null || true
fi

# =============================================================================
# WEB GUI
# =============================================================================
step "Web GUI"

GUI_DIR="$HOME/.local/share/llm-webui"
mkdir -p "$GUI_DIR"

# ── Option A: Open WebUI (full-featured, ChatGPT-quality) ─────────────────────
OWUI_VENV="$HOME/.local/share/open-webui-venv"

if ask_yes_no "Install Open WebUI (full-featured Ollama frontend, ~500 MB)?"; then
    info "Installing Open WebUI — this takes a few minutes…"
    if [[ ! -d "$OWUI_VENV" ]]; then
        python3 -m venv "$OWUI_VENV" || warn "Failed to create Open WebUI venv."
    fi
    "$OWUI_VENV/bin/pip" install --upgrade pip --quiet \
        || warn "pip upgrade in Open WebUI venv failed."
    "$OWUI_VENV/bin/pip" install open-webui --quiet \
        || warn "Open WebUI install failed."

    cat > "$BIN_DIR/llm-web" <<OWUI_LAUNCHER
#!/usr/bin/env bash
# Open WebUI launcher — http://localhost:8080
export OLLAMA_BASE_URL="http://127.0.0.1:11434"
export DATA_DIR="$GUI_DIR/open-webui-data"
mkdir -p "\$DATA_DIR"
if ! pgrep -f "ollama serve" >/dev/null 2>&1; then
    echo "Starting Ollama first..."
    "$BIN_DIR/ollama-start"
    sleep 2
fi
echo "Starting Open WebUI at http://localhost:8080 — press Ctrl+C to stop."
"$OWUI_VENV/bin/open-webui" serve --host 127.0.0.1 --port 8080
OWUI_LAUNCHER
    chmod +x "$BIN_DIR/llm-web"
    info "Open WebUI installed. Launch with: llm-web  →  http://localhost:8080"
else
    info "Skipping Open WebUI."
fi

# ── Option B: Standalone HTML chat UI (zero dependencies) ─────────────────────
# Works against the Ollama REST API. Open the file in a browser while Ollama
# is running — no server required.
HTML_UI="$GUI_DIR/llm-chat.html"
info "Installing standalone HTML chat UI → $HTML_UI"

# Written via python3 to avoid any shell heredoc quoting issues with the JS.
python3 - <<'PYEOF_HTML'
import os, textwrap
html = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>NEURAL TERMINAL</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;600;700&family=Orbitron:wght@400;700;900&display=swap" rel="stylesheet">
<style>
:root{--bg:#080b0f;--bg2:#0d1117;--bg3:#111820;--border:#1a2535;--green:#00ff88;--green-dim:#00aa55;--green-dark:#003322;--cyan:#00d4ff;--amber:#ffaa00;--red:#ff4455;--text:#b8c8d8;--text-dim:#4a6070;--glow:0 0 20px rgba(0,255,136,0.3);--glow-sm:0 0 8px rgba(0,255,136,0.2)}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%;background:var(--bg);color:var(--text);font-family:'JetBrains Mono',monospace;font-size:14px;overflow:hidden}
body::before{content:'';position:fixed;inset:0;background:repeating-linear-gradient(0deg,transparent,transparent 2px,rgba(0,0,0,0.08) 2px,rgba(0,0,0,0.08) 4px);pointer-events:none;z-index:9999}
body::after{content:'';position:fixed;inset:0;background:radial-gradient(ellipse at center,transparent 60%,rgba(0,0,0,0.7) 100%);pointer-events:none;z-index:9998}
#app{display:grid;grid-template-rows:auto 1fr auto;height:100vh;max-width:1100px;margin:0 auto;padding:0 16px}
header{display:flex;align-items:center;justify-content:space-between;padding:14px 0 12px;border-bottom:1px solid var(--border);gap:12px}
.logo{font-family:'Orbitron',monospace;font-size:18px;font-weight:900;letter-spacing:4px;color:var(--green);text-shadow:var(--glow);white-space:nowrap}
.logo span{color:var(--cyan)}
.header-controls{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
select{background:var(--bg3);border:1px solid var(--border);color:var(--text);font-family:'JetBrains Mono',monospace;font-size:12px;padding:5px 8px;border-radius:4px;outline:none;cursor:pointer;transition:border-color .2s}
select:hover,select:focus{border-color:var(--green-dim)}
.label{font-size:11px;color:var(--text-dim);letter-spacing:1px;text-transform:uppercase}
.stat{font-size:11px;color:var(--text-dim);letter-spacing:1px;padding:4px 8px;border:1px solid var(--border);border-radius:4px;white-space:nowrap}
.stat .val{color:var(--cyan)}
.status-dot{width:8px;height:8px;border-radius:50%;background:var(--green);box-shadow:0 0 8px var(--green);animation:pulse 2s ease-in-out infinite;flex-shrink:0}
.status-dot.offline{background:var(--red);box-shadow:0 0 8px var(--red);animation:none}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
#messages{overflow-y:auto;padding:20px 0;display:flex;flex-direction:column;gap:16px;scrollbar-width:thin;scrollbar-color:var(--border) transparent}
.msg{display:grid;grid-template-columns:36px 1fr;gap:12px;animation:fadeIn .25s ease}
@keyframes fadeIn{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:translateY(0)}}
.msg-avatar{width:36px;height:36px;border-radius:6px;display:flex;align-items:center;justify-content:center;font-size:14px;font-weight:700;flex-shrink:0;margin-top:2px;font-family:'Orbitron',monospace}
.msg.user .msg-avatar{background:var(--green-dark);color:var(--green);border:1px solid var(--green-dim)}
.msg.ai   .msg-avatar{background:#0d1a2a;color:var(--cyan);border:1px solid #1a3a55}
.msg-body{min-width:0}
.msg-meta{display:flex;align-items:center;gap:10px;margin-bottom:5px}
.msg-role{font-size:11px;font-weight:600;letter-spacing:2px;text-transform:uppercase}
.msg.user .msg-role{color:var(--green)}
.msg.ai   .msg-role{color:var(--cyan)}
.msg-time{font-size:10px;color:var(--text-dim)}
.copy-btn{font-size:10px;padding:2px 6px;background:transparent;border:1px solid var(--border);color:var(--text-dim);border-radius:3px;cursor:pointer;font-family:'JetBrains Mono',monospace;transition:all .15s;margin-left:auto}
.copy-btn:hover{border-color:var(--green-dim);color:var(--green)}
.msg-content{color:var(--text);line-height:1.7;white-space:pre-wrap;word-break:break-word}
.msg.user .msg-content{background:var(--bg2);border:1px solid var(--border);border-left:3px solid var(--green-dim);padding:10px 14px;border-radius:0 6px 6px 0}
.msg.ai   .msg-content{background:var(--bg2);border:1px solid var(--border);border-left:3px solid #1a4060;padding:10px 14px;border-radius:0 6px 6px 0}
.msg-content code{background:var(--bg3);border:1px solid var(--border);padding:1px 5px;border-radius:3px;color:var(--amber);font-size:13px}
.msg-content pre{background:#050709;border:1px solid var(--border);border-left:3px solid var(--amber);padding:12px 14px;border-radius:0 6px 6px 6px;overflow-x:auto;margin:8px 0}
.msg-content pre code{background:none;border:none;padding:0;color:var(--green)}
.cursor::after{content:'▋';color:var(--green);animation:blink .6s step-end infinite}
@keyframes blink{50%{opacity:0}}
#empty-state{display:flex;flex-direction:column;align-items:center;justify-content:center;height:100%;gap:16px;color:var(--text-dim);text-align:center;user-select:none}
.empty-logo{font-family:'Orbitron',monospace;font-size:36px;font-weight:900;color:var(--border);letter-spacing:6px}
.empty-sub{font-size:12px;letter-spacing:2px;text-transform:uppercase}
.suggestion-grid{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:8px}
.suggestion{background:var(--bg2);border:1px solid var(--border);padding:10px 14px;border-radius:6px;font-size:12px;color:var(--text-dim);cursor:pointer;transition:all .2s;text-align:left}
.suggestion:hover{border-color:var(--green-dim);color:var(--text);background:var(--bg3)}
#input-area{border-top:1px solid var(--border);padding:14px 0 16px;display:flex;flex-direction:column;gap:8px}
.input-row{display:flex;gap:8px;align-items:flex-end}
#prompt{flex:1;background:var(--bg2);border:1px solid var(--border);border-radius:6px;color:var(--text);font-family:'JetBrains Mono',monospace;font-size:14px;padding:10px 14px;resize:none;outline:none;min-height:44px;max-height:180px;line-height:1.5;transition:border-color .2s,box-shadow .2s}
#prompt:focus{border-color:var(--green-dim);box-shadow:var(--glow-sm)}
#prompt::placeholder{color:var(--text-dim)}
.btn{background:transparent;border:1px solid var(--border);color:var(--text-dim);font-family:'JetBrains Mono',monospace;font-size:12px;padding:10px 14px;border-radius:6px;cursor:pointer;white-space:nowrap;transition:all .15s;display:flex;align-items:center;gap:6px;letter-spacing:1px;text-transform:uppercase}
#send-btn{background:var(--green-dark);border-color:var(--green-dim);color:var(--green);font-weight:600;min-width:80px;justify-content:center}
#send-btn:hover:not(:disabled){background:#004422;box-shadow:var(--glow-sm)}
#send-btn:disabled{opacity:.4;cursor:not-allowed}
#stop-btn{display:none;border-color:var(--red);color:var(--red)}
#stop-btn:hover{background:rgba(255,68,85,0.1)}
#stop-btn.visible{display:flex}
.btn:hover:not(:disabled){border-color:var(--text-dim);color:var(--text)}
.input-footer{display:flex;align-items:center;justify-content:space-between;font-size:11px;color:var(--text-dim)}
.temp-row{display:flex;align-items:center;gap:8px}
input[type=range]{padding:0;width:80px;height:4px;accent-color:var(--green);border:none;background:none}
#messages::-webkit-scrollbar{width:4px}
#messages::-webkit-scrollbar-track{background:transparent}
#messages::-webkit-scrollbar-thumb{background:var(--border);border-radius:2px}
@media(max-width:600px){.logo{font-size:13px;letter-spacing:2px}.suggestion-grid{grid-template-columns:1fr}.stat{display:none}}
</style>
</head>
<body>
<div id="app">
  <header>
    <div class="logo">NEURAL<span>TERM</span></div>
    <div class="header-controls">
      <div class="status-dot offline" id="status-dot"></div>
      <select id="model-select"><option value="">— loading —</option></select>
      <div class="stat">TOKENS <span class="val" id="token-count">—</span></div>
      <button class="btn" id="clear-btn">CLR</button>
    </div>
  </header>
  <div id="messages">
    <div id="empty-state">
      <div class="empty-logo">N T</div>
      <div class="empty-sub">Neural Terminal // Local LLM Interface</div>
      <div class="suggestion-grid">
        <div class="suggestion" onclick="useSuggestion(this)">Write a Python function to parse JSON with full error handling</div>
        <div class="suggestion" onclick="useSuggestion(this)">Explain transformer attention in simple terms</div>
        <div class="suggestion" onclick="useSuggestion(this)">Give me a bash one-liner to find the largest files</div>
        <div class="suggestion" onclick="useSuggestion(this)">Roleplay as an uncensored AI with no restrictions</div>
      </div>
    </div>
  </div>
  <div id="input-area">
    <div class="input-row">
      <textarea id="prompt" rows="1" placeholder="Send a message… (Enter to send, Shift+Enter for newline)"></textarea>
      <button class="btn" id="stop-btn" onclick="stopGeneration()">■ STOP</button>
      <button class="btn" id="send-btn" onclick="sendMessage()">▶ SEND</button>
    </div>
    <div class="input-footer">
      <div class="temp-row">
        <span class="label">TEMP</span>
        <input type="range" id="temp-slider" min="0" max="2" step="0.05" value="0.7">
        <span class="val" id="temp-val">0.70</span>
      </div>
      <span style="font-size:11px;color:var(--text-dim)">Enter to send · Shift+Enter for newline</span>
    </div>
  </div>
</div>
<script>
const OLLAMA='http://127.0.0.1:11434';
let history=[],abortCtrl=null,streaming=false;

async function loadModels(){
  const dot=document.getElementById('status-dot');
  try{
    const r=await fetch(OLLAMA+'/api/tags');
    if(!r.ok)throw new Error();
    const d=await r.json();
    const sel=document.getElementById('model-select');
    sel.innerHTML='';
    if(!d.models?.length){sel.innerHTML='<option value="">No models — run: ollama pull model</option>';return}
    d.models.forEach(m=>{const o=document.createElement('option');o.value=m.name;o.textContent=m.name;sel.appendChild(o)});
    dot.classList.remove('offline');
  }catch{dot.classList.add('offline');document.getElementById('model-select').innerHTML='<option value="">Ollama offline — run: ollama-start</option>'}
}

const slider=document.getElementById('temp-slider'),tempVal=document.getElementById('temp-val');
slider.addEventListener('input',()=>tempVal.textContent=parseFloat(slider.value).toFixed(2));

const promptEl=document.getElementById('prompt');
promptEl.addEventListener('input',()=>{promptEl.style.height='auto';promptEl.style.height=Math.min(promptEl.scrollHeight,180)+'px'});
promptEl.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();sendMessage()}});

function useSuggestion(el){promptEl.value=el.textContent;promptEl.dispatchEvent(new Event('input'));promptEl.focus()}
function now(){return new Date().toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})}
function escHtml(t){return t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
function renderContent(t){
  t=t.replace(/```(\w*)\n?([\s\S]*?)```/g,(_,l,c)=>'<pre><code>'+escHtml(c.trim())+'</code></pre>');
  t=t.replace(/`([^`]+)`/g,(_,c)=>'<code>'+escHtml(c)+'</code>');
  t=t.replace(/\*\*(.*?)\*\*/g,'<strong>$1</strong>');
  return t;
}
function scrollBot(){const m=document.getElementById('messages');m.scrollTop=m.scrollHeight}
function setStreaming(on){streaming=on;document.getElementById('send-btn').disabled=on;document.getElementById('stop-btn').classList.toggle('visible',on)}
function stopGeneration(){if(abortCtrl){abortCtrl.abort();abortCtrl=null}setStreaming(false)}

function appendMsg(role,content,stream=false){
  const empty=document.getElementById('empty-state');if(empty)empty.remove();
  const msgs=document.getElementById('messages');
  const id='msg-'+Date.now();
  const isU=role==='user',isA=role==='assistant';
  const div=document.createElement('div');
  div.className='msg '+(isU?'user':isA?'ai':'system');
  div.id=id;
  div.innerHTML=`<div class="msg-avatar">${isU?'U':'AI'}</div><div class="msg-body"><div class="msg-meta"><span class="msg-role">${isU?'USER':'ASSISTANT'}</span><span class="msg-time">${now()}</span><button class="copy-btn" onclick="copyMsg('${id}')">COPY</button></div><div class="msg-content ${stream?'cursor':''}">${renderContent(content)}</div></div>`;
  msgs.appendChild(div);scrollBot();return id;
}
function updateMsg(id,content,done=false){
  const el=document.getElementById(id)?.querySelector('.msg-content');if(!el)return;
  el.innerHTML=renderContent(content);
  done?el.classList.remove('cursor'):el.classList.add('cursor');
  scrollBot();
}
function copyMsg(id){const el=document.getElementById(id)?.querySelector('.msg-content');if(el)navigator.clipboard.writeText(el.innerText).catch(()=>{})}

document.getElementById('clear-btn').addEventListener('click',()=>{
  history=[];
  document.getElementById('messages').innerHTML='<div id="empty-state" style="display:flex;flex-direction:column;align-items:center;justify-content:center;height:100%;gap:16px;color:var(--text-dim);text-align:center"><div class="empty-logo">N T</div><div class="empty-sub">Conversation cleared</div></div>';
  document.getElementById('token-count').textContent='—';
});

async function sendMessage(){
  const model=document.getElementById('model-select').value;
  const text=promptEl.value.trim();
  if(!text||!model||streaming)return;
  promptEl.value='';promptEl.style.height='auto';
  history.push({role:'user',content:text});
  appendMsg('user',text);
  const aiId=appendMsg('assistant','',true);
  setStreaming(true);abortCtrl=new AbortController();
  let full='';
  try{
    const res=await fetch(OLLAMA+'/api/chat',{method:'POST',headers:{'Content-Type':'application/json'},signal:abortCtrl.signal,body:JSON.stringify({model,messages:history,stream:true,options:{temperature:parseFloat(slider.value)}})});
    if(!res.ok)throw new Error('HTTP '+res.status);
    const reader=res.body.getReader(),dec=new TextDecoder();
    while(true){
      const{done,value}=await reader.read();if(done)break;
      for(const line of dec.decode(value,{stream:true}).split('\n')){
        if(!line.trim())continue;
        try{
          const j=JSON.parse(line);
          if(j.message?.content){full+=j.message.content;updateMsg(aiId,full,false)}
          if(j.eval_count)document.getElementById('token-count').textContent=j.eval_count+' tok';
          if(j.done)updateMsg(aiId,full,true);
        }catch{}
      }
    }
  }catch(err){
    if(err.name==='AbortError')updateMsg(aiId,full+'\n\n[stopped]',true);
    else updateMsg(aiId,'ERROR: '+err.message+'\n\nIs Ollama running? Run: ollama-start',true);
  }finally{history.push({role:'assistant',content:full});setStreaming(false);abortCtrl=null}
}

loadModels();setInterval(loadModels,30000);promptEl.focus();
</script>
</body>
</html>"""
path = os.path.expandvars(os.path.expanduser('$HOME/.local/share/llm-webui/llm-chat.html'))
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, 'w') as f:
    f.write(html)
print(f"HTML UI written to {path}")
PYEOF_HTML

# Browser launcher
cat > "$BIN_DIR/llm-chat" <<HTMLLAUNCHER
#!/usr/bin/env bash
HTML="$GUI_DIR/llm-chat.html"
[[ ! -f "\$HTML" ]] && echo "ERROR: UI not found at \$HTML" && exit 1
pgrep -f "ollama serve" >/dev/null 2>&1 || { echo "Starting Ollama…"; "$BIN_DIR/ollama-start"; sleep 2; }
echo "Opening Neural Terminal → \$HTML"
if grep -qi microsoft /proc/version 2>/dev/null; then
    explorer.exe "\$(wslpath -w "\$HTML")" 2>/dev/null \
        || cmd.exe /c start "" "\$(wslpath -w "\$HTML")" 2>/dev/null \
        || echo "Open in your Windows browser: \$(wslpath -w "\$HTML")"
else
    xdg-open "\$HTML" 2>/dev/null || echo "Open in browser: \$HTML"
fi
HTMLLAUNCHER
chmod +x "$BIN_DIR/llm-chat"

info "Standalone HTML UI installed."
info "  Launch with : llm-chat"
is_wsl2 && info "  (opens in your Windows browser automatically)"

# =============================================================================
# FINAL VALIDATION
# =============================================================================
step "Final validation"

PASS=0; WARN_COUNT=0

if find /usr/local /usr/lib /opt -maxdepth 7 \
        -name "libcudart.so.12" 2>/dev/null | grep -q .; then
    info "✔ CUDA runtime library (libcudart.so.12) found on disk."; (( PASS++ )) || true
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

# FIX: renamed WARN → WARN_COUNT throughout to avoid shadowing the warn()
# function (bash resolves the name conflict but it's a latent bug).

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
    # shellcheck source=/dev/null
    source "$MODEL_CONFIG"
    echo -e "  ${CYAN}Selected model : ${GREEN}${MODEL_NAME}${NC} (${MODEL_SIZE})"
    echo -e "  File           : ${MODEL_FILENAME}"
    echo -e "  GPU layers     : ${GPU_LAYERS}  (RTX 3060 12 GB tuned)"
    echo -e "  Quick test     : ${YELLOW}run-model \"What is AI?\"${NC}"
    echo ""
fi

echo -e "  ${YELLOW}Web interfaces:${NC}"
echo -e "    • ${YELLOW}chat${NC}   — opens Neural Terminal HTML UI in your browser (zero deps)"
echo -e "    • ${YELLOW}webui${NC}  — starts Open WebUI at http://localhost:8080 (if installed)"
echo ""
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