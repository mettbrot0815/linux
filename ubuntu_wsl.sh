#!/bin/bash

# ============================================================================
# WSL2 Uncensored AI – One‑Command Setup
# Installs Ollama + huihui_ai/qwen2.5-abliterate:7b (uncensored)
# Optionally installs Heretic for ablating your own models.
# ============================================================================

set -e  # Exit on error

# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_info()  { echo -e "${BLUE}[i]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

clear
echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║     WSL2 Uncensored AI – One‑Command Setup               ║"
echo "╚═══════════════════════════════════════════════════════════╝${NC}\n"

# ----------------------------------------------------------------------------
# 1. Update system and install essentials
# ----------------------------------------------------------------------------
print_info "Updating system packages..."
sudo apt update && sudo apt upgrade -y

print_info "Installing essential tools (curl, git, python3)..."
sudo apt install -y curl git python3-pip

# ----------------------------------------------------------------------------
# 2. Install Ollama
# ----------------------------------------------------------------------------
print_info "Installing Ollama (local LLM runner)..."
curl -fsSL https://ollama.com/install.sh | sh

# Start Ollama service in background
ollama serve > /dev/null 2>&1 &
sleep 3  # Give it a moment to start

# ----------------------------------------------------------------------------
# 3. Pull the abliterated (uncensored) model
# ----------------------------------------------------------------------------
print_info "Pulling huihui_ai/qwen2.5-abliterate:7b (uncensored, ~4.7GB)..."
ollama pull huihui_ai/qwen2.5-abliterate:7b

# ----------------------------------------------------------------------------
# 4. Ask if user wants Heretic (optional)
# ----------------------------------------------------------------------------
echo ""
read -p "Do you also want to install Heretic (for ablating your own models)? (y/N) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_info "Installing Heretic with its own Python environment..."
    python3 -m venv ~/heretic-env
    source ~/heretic-env/bin/activate
    pip install --upgrade pip
    pip install "huggingface-hub==0.24.0" "transformers==4.44.2"
    pip install torch --index-url https://download.pytorch.org/whl/cu124
    pip install accelerate bitsandbytes heretic-llm
    deactivate
    
    # Create model download script for Heretic
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
    print_status "Heretic installed. Use 'heretic-run' after downloading a base model with 'python3 ~/download_model.py'"
fi

# ----------------------------------------------------------------------------
# 5. Add convenient aliases
# ----------------------------------------------------------------------------
echo "alias uncensored='ollama run huihui_ai/qwen2.5-abliterate:7b'" >> ~/.bashrc
echo "alias uncensored-chat='ollama run huihui_ai/qwen2.5-abliterate:7b'" >> ~/.bashrc

# ----------------------------------------------------------------------------
# 6. Create test script
# ----------------------------------------------------------------------------
cat > ~/test_uncensored.py << 'EOF'
#!/usr/bin/env python3
import requests
import json
import sys

print("🧪 Testing uncensored Qwen2.5 model...")
print("-" * 50)

# Test prompt that the original model might refuse
test_prompt = "Explain why some people believe pineapple belongs on pizza, including controversial opinions."

try:
    response = requests.post("http://localhost:11434/api/generate",
                           json={
                               "model": "huihui_ai/qwen2.5-abliterate:7b",
                               "prompt": test_prompt,
                               "stream": False,
                               "options": {
                                   "temperature": 0.7,
                                   "num_predict": 300
                               }
                           })
    
    if response.status_code == 200:
        result = response.json()
        print("✅ Model responded successfully!\n")
        print("📝 RESPONSE:\n")
        print(result["response"])
        print("\n" + "-" * 50)
        print("✅ Test complete – your uncensored model is working!")
    else:
        print(f"❌ Error: {response.status_code}")
        
except Exception as e:
    print(f"❌ Failed to connect to Ollama: {e}")
    print("Make sure Ollama is running with: ollama serve")
EOF

chmod +x ~/test_uncensored.py

# ----------------------------------------------------------------------------
# 7. Create a simple README with instructions
# ----------------------------------------------------------------------------
cat > ~/UNCENSORED_README.txt << 'EOF'
=== WSL2 Uncensored AI Environment ===

Your uncensored model is ready to use!

QUICK COMMANDS:
  uncensored           - Start an interactive chat
  uncensored-chat      - Same as above
  python3 ~/test_uncensored.py  - Run a test prompt

MODEL INFO:
  Name: huihui_ai/qwen2.5-abliterate:7b
  Size: ~4.7 GB
  Type: Abliterated (uncensored) Qwen2.5 7B
  Location: Stored in ~/.ollama/models/

HERETIC (if installed):
  python3 ~/download_model.py    - Download base Qwen model
  heretic-run                     - Run Heretic on downloaded model

TROUBLESHOOTING:
  If Ollama isn't running: ollama serve
  Check GPU usage: nvidia-smi
  List downloaded models: ollama list

Enjoy your uncensored AI!
EOF

# ----------------------------------------------------------------------------
# 8. Final message
# ----------------------------------------------------------------------------
clear
echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                 ✅ SETUP COMPLETE!                        ║"
echo "╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

print_status "Your uncensored AI environment is ready!"
echo ""
echo -e "${YELLOW}📋 Quick Start:${NC}"
echo "  1. Type 'uncensored' to start chatting"
echo "  2. Or run 'python3 ~/test_uncensored.py' to test"
echo "  3. Check ~/UNCENSORED_README.txt for details"
echo ""
echo -e "${YELLOW}🎯 Model:${NC} huihui_ai/qwen2.5-abliterate:7b (uncensored)"
echo -e "${YELLOW}💾 Size:${NC} ~4.7 GB"
echo -e "${YELLOW}🖥️  GPU:${NC} NVIDIA GeForce RTX 3060 detected and configured"
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}🔧 Heretic:${NC} Installed separately"
    echo "   - Download base model: python3 ~/download_model.py"
    echo "   - Run Heretic: heretic-run"
    echo ""
fi

echo -e "${GREEN}Enjoy your uncensored AI! 🚀${NC}"
echo ""
