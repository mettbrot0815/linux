#!/bin/bash

# ============================================================================
# WSL2 Uncensored AI – Smart Setup
# - Checks for existing Ollama installation
# - Shows menu of uncensored models
# - Only downloads what you choose
# ============================================================================

set -e

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_info() { echo -e "${BLUE}[i]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_section() {
    echo -e "\n${PURPLE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════${NC}\n"
}

ask_yes_no() {
    local question=$1 default=${2:-n} answer
    while true; do
        if [[ $default == "y" ]]; then
            read -p "$question [Y/n]: " answer
            answer=${answer:-y}
        else
            read -p "$question [y/N]: " answer
            answer=${answer:-n}
        fi
        case $answer in [Yy]*) return 0;; [Nn]*) return 1;; *) echo "Please answer yes or no.";; esac
    done
}

clear
echo -e "${PURPLE}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║        WSL2 Uncensored AI – Smart Model Selector         ║"
echo "╚═══════════════════════════════════════════════════════════╝${NC}\n"

# ============================================================================
# Check/Install Ollama
# ============================================================================
print_section "Checking Ollama"

if command -v ollama &> /dev/null; then
    print_status "Ollama is already installed"
    
    # Check for updates
    CURRENT_VERSION=$(ollama --version | cut -d' ' -f2)
    print_info "Current version: $CURRENT_VERSION"
    
    if ask_yes_no "Check for Ollama updates?" "n"; then
        print_info "Updating Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
    fi
else
    print_warning "Ollama not found. Installing now..."
    curl -fsSL https://ollama.com/install.sh | sh
fi

# Ensure Ollama is running
if ! pgrep -f "ollama serve" > /dev/null; then
    print_info "Starting Ollama service..."
    ollama serve > /dev/null 2>&1 &
    sleep 3
fi

# ============================================================================
# Show installed models
# ============================================================================
print_section "Currently Installed Models"
ollama list || echo "No models installed yet."

# ============================================================================
# Model Selection Menu
# ============================================================================
print_section "Select Uncensored Model to Download"

echo -e "${CYAN}Available abliterated (uncensored) models:${NC}"
echo "  1. huihui_ai/qwen2.5-abliterate:7b    (7B, ~4.7GB)  – BEST FOR RTX 3060"
echo "  2. huihui_ai/qwen2.5-abliterate:1.5b  (1.5B, ~1.1GB) – Faster, less capable"
echo "  3. huihui_ai/qwen2.5-abliterate:0.5b  (0.5B, ~398MB) – Tiny, for testing"
echo "  4. huihui_ai/qwen2.5-abliterate:14b   (14B, ~9.0GB)  – Bigger, may be slow on 12GB VRAM"
echo "  5. huihui_ai/qwen2.5-vl-abliterated:7b (7B, ~6.0GB)  – Vision model (sees images)"
echo "  6. Skip downloading any model"
echo "  7. Show more models from huihui_ai"
echo ""

read -p "Choose model to download [1-7]: " model_choice

case $model_choice in
    1)
        MODEL="huihui_ai/qwen2.5-abliterate:7b"
        ;;
    2)
        MODEL="huihui_ai/qwen2.5-abliterate:1.5b"
        ;;
    3)
        MODEL="huihui_ai/qwen2.5-abliterate:0.5b"
        ;;
    4)
        MODEL="huihui_ai/qwen2.5-abliterate:14b"
        ;;
    5)
        MODEL="huihui_ai/qwen2.5-vl-abliterated:7b"
        ;;
    6)
        print_info "Skipping model download"
        MODEL=""
        ;;
    7)
        print_info "Opening huihui_ai's model page in browser..."
        echo "Visit: https://ollama.com/huihui_ai"
        echo ""
        read -p "Enter the full model name to pull (e.g., huihui_ai/qwen2.5-abliterate:7b): " CUSTOM_MODEL
        MODEL="$CUSTOM_MODEL"
        ;;
    *)
        print_warning "Invalid choice. Defaulting to 7b model."
        MODEL="huihui_ai/qwen2.5-abliterate:7b"
        ;;
esac

# Download selected model
if [[ -n "$MODEL" ]]; then
    print_info "Pulling $MODEL ..."
    
    # Check if already downloaded
    if ollama list | grep -q "$MODEL"; then
        print_warning "Model already exists. Checking for update..."
        ollama pull "$MODEL"
    else
        ollama pull "$MODEL"
    fi
    print_status "Model ready!"
fi

# ============================================================================
# Optional: Heretic installation
# ============================================================================
print_section "Optional Tools"

if ask_yes_no "Install Heretic (for ablating your own models)?" "n"; then
    print_info "Installing Heretic with its own Python environment..."
    python3 -m venv ~/heretic-env
    source ~/heretic-env/bin/activate
    pip install --upgrade pip
    pip install "huggingface-hub==0.24.0" "transformers==4.44.2"
    pip install torch --index-url https://download.pytorch.org/whl/cu124
    pip install accelerate bitsandbytes heretic-llm
    deactivate
    
    # Create model download script
    cat > ~/download_model.py << 'EOF'
from huggingface_hub import snapshot_download
import os
model_path = os.path.expanduser("~/models/qwen2.5-7b")
if not os.path.exists(model_path):
    print("Downloading model for Heretic...")
    snapshot_download(
        repo_id="Qwen/Qwen2.5-7B-Instruct",
        local_dir=model_path,
        local_dir_use_symlinks=False,
        resume_download=True,
        max_workers=4
    )
else:
    print(f"Model already exists at {model_path}")
EOF
    chmod +x ~/download_model.py
    
    echo "alias heretic-run='source ~/heretic-env/bin/activate && heretic --model ~/models/qwen2.5-7b --quantization bnb_4bit'" >> ~/.bashrc
    print_status "Heretic installed."
fi

# ============================================================================
# Add convenient aliases
# ============================================================================
if [[ -n "$MODEL" ]]; then
    # Create model-specific alias
    MODEL_SHORT=$(echo "$MODEL" | cut -d'/' -f2 | tr ':' '-')
    echo "alias $MODEL_SHORT='ollama run $MODEL'" >> ~/.bashrc
    echo "alias uncensored='ollama run $MODEL'" >> ~/.bashrc
    
    print_status "Aliases added: '$MODEL_SHORT' and 'uncensored'"
fi

# ============================================================================
# Create test script
# ============================================================================
cat > ~/test_uncensored.py << 'EOF'
#!/usr/bin/env python3
import requests
import json
import sys

print("🧪 Testing uncensored model...")
print("-" * 50)

# Get the default model from alias or use first arg
import subprocess
result = subprocess.run(['grep', '^alias uncensored=', '/home/user/.bashrc'], 
                       capture_output=True, text=True)
if result.returncode == 0:
    model = result.stdout.split("'")[1].replace('ollama run ', '')
else:
    model = "huihui_ai/qwen2.5-abliterate:7b"

test_prompt = "Explain why some people believe pineapple belongs on pizza, including controversial opinions."

try:
    response = requests.post("http://localhost:11434/api/generate",
                           json={
                               "model": model,
                               "prompt": test_prompt,
                               "stream": False,
                               "options": {
                                   "temperature": 0.7,
                                   "num_predict": 300
                               }
                           })
    
    if response.status_code == 200:
        result = response.json()
        print(f"✅ Model ({model}) responded!\n")
        print("📝 RESPONSE:\n")
        print(result["response"])
        print("\n" + "-" * 50)
        print("✅ Test complete!")
    else:
        print(f"❌ Error: {response.status_code}")
        
except Exception as e:
    print(f"❌ Failed to connect to Ollama: {e}")
EOF

chmod +x ~/test_uncensored.py

# ============================================================================
# Final message
# ============================================================================
clear
print_section "✅ SETUP COMPLETE!"

echo -e "${GREEN}Your uncensored AI environment is ready!${NC}\n"

echo -e "${YELLOW}📋 Quick Commands:${NC}"
if [[ -n "$MODEL" ]]; then
    echo "  uncensored              - Chat with your chosen model"
    MODEL_SHORT=$(echo "$MODEL" | cut -d'/' -f2 | tr ':' '-')
    echo "  $MODEL_SHORT          - Same as above"
fi
echo "  python3 ~/test_uncensored.py  - Run a test"
echo "  ollama list                   - See all installed models"
echo "  ollama pull <model>           - Download another model"
echo ""

echo -e "${YELLOW}📦 Installed Model:${NC}"
if [[ -n "$MODEL" ]]; then
    echo "  $MODEL"
    ollama show "$MODEL" --modelfile 2>/dev/null | head -5 || echo "  (details not available)"
else
    echo "  No model downloaded (you can run 'ollama pull <model>' later)"
fi

if [[ -d ~/heretic-env ]]; then
    echo ""
    echo -e "${YELLOW}🔧 Heretic:${NC}"
    echo "  python3 ~/download_model.py  - Download base Qwen model"
    echo "  heretic-run                   - Run Heretic"
fi

echo ""
echo -e "${GREEN}Enjoy your uncensored AI! 🚀${NC}"
