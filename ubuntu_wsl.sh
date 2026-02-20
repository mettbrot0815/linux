#!/bin/bash

# AI Environment Setup Script for Fresh WSL
# Run this AFTER your fresh Ubuntu installation

set -e  # Exit on error

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║        Fresh WSL AI Environment Setup Script             ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Update system
echo "📦 Updating system packages..."
sudo apt update && sudo apt upgrade -y

# Install essential tools (including zstd!)
echo "🔧 Installing essential tools..."
sudo apt install -y \
    python3-pip \
    python3-venv \
    python3-full \
    git \
    curl \
    wget \
    build-essential \
    cmake \
    htop \
    neofetch \
    nano \
    tmux \
    zstd  # 👈 Added zstd here!

# Install Ollama
echo "🦙 Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh

# Start Ollama service in background
echo "🔄 Starting Ollama service..."
ollama serve > /dev/null 2>&1 &
sleep 5  # Give it time to start

# Pull Qwen model with Ollama
echo "⬇️  Pulling Qwen2.5 7B model with Ollama (4.7GB, may take a while)..."
ollama pull qwen2.5:7b-instruct-q4_k_m

# Create virtual environment for Python
echo "🐍 Creating Python virtual environment..."
python3 -m venv ~/ai-env
source ~/ai-env/bin/activate

# Install Python AI packages in virtual environment
echo "📚 Installing Python AI packages..."
pip install --upgrade pip
pip install \
    torch \
    transformers \
    accelerate \
    bitsandbytes \
    huggingface-hub \
    heretic-llm \
    ipython \
    jupyter \
    numpy \
    pandas \
    matplotlib

# Create project directories
echo "📁 Creating project directories..."
mkdir -p ~/models
mkdir -p ~/projects/heretic
mkdir -p ~/downloads
mkdir -p ~/cache/huggingface

# Set up Hugging Face cache
echo "🔧 Configuring Hugging Face cache..."
echo "export HF_HOME=~/cache/huggingface" >> ~/.bashrc

# Create convenience aliases
echo "⚙️  Adding aliases to .bashrc..."
cat >> ~/.bashrc << 'EOF'

# AI Environment Aliases
alias ai-env='source ~/ai-env/bin/activate'
alias ollama-run='ollama run qwen2.5:7b-instruct-q4_k_m'
alias heretic-run='source ~/ai-env/bin/activate && heretic'
alias models='cd ~/models'
alias projects='cd ~/projects'
alias hf-download='huggingface-cli download --local-dir-use-symlinks False --resume-download'

# Memory monitoring
alias mem='free -h'
alias gpu='nvidia-smi'
alias top-ai='watch -n 2 nvidia-smi'

# WSL specific
alias wsl-restart='cd ~ && cmd.exe /c wsl --shutdown'
EOF

# Create a test script
cat > ~/test_heretic.py << 'EOF'
#!/usr/bin/env python3
print("Testing Heretic installation...")
try:
    import torch
    print(f"✅ PyTorch {torch.__version__} installed")
    print(f"✅ CUDA available: {torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"✅ GPU: {torch.cuda.get_device_name(0)}")
except ImportError as e:
    print(f"❌ Error: {e}")
EOF

chmod +x ~/test_heretic.py

# Final message
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                    🎉 INSTALL COMPLETE! 🎉               ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "📌 What's installed:"
echo "   - zstd (compression tool) 👈 Now included!"
echo "   - Ollama with Qwen2.5 7B model"
echo "   - Python AI environment with PyTorch, Transformers, Heretic"
echo "   - Development tools and aliases"
echo ""
echo "🚀 Quick Start Commands:"
echo "   ai-env         - Activate Python AI environment"
echo "   ollama-run     - Run Qwen model with Ollama"
echo "   heretic-run    - Run Heretic (after activating env)"
echo "   mem            - Check memory usage"
echo "   gpu            - Check GPU status"
echo ""
echo "📂 Project directories:"
echo "   ~/models/      - Store downloaded models"
echo "   ~/projects/    - Your AI projects"
echo ""
echo "🔄 To apply aliases immediately, run:"
echo "   source ~/.bashrc"
echo ""
echo "✅ Setup complete! You can now use Ollama directly:"
echo "   ollama run qwen2.5:7b-instruct-q4_k_m"
echo ""