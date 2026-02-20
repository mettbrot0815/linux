#!/bin/bash

# WSL2 Ultimate AI & Development Environment Setup Script - FIXED VERSION
# Run this AFTER your fresh Ubuntu installation

set -e  # Exit on error

# Color codes for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_section() {
    echo -e "\n${PURPLE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════${NC}\n"
}

# Function to ask yes/no questions
ask_yes_no() {
    local question=$1
    local default=${2:-n}
    local answer
    
    while true; do
        if [[ $default == "y" ]]; then
            read -p "$question [Y/n]: " answer
            answer=${answer:-y}
        else
            read -p "$question [y/N]: " answer
            answer=${answer:-n}
        fi
        
        case $answer in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# Welcome screen
clear
echo -e "${PURPLE}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║     WSL2 Ultimate AI & Development Environment Setup     ║"
echo "║                    FIXED VERSION                         ║"
echo "╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

print_warning "This script will install various tools on your fresh WSL Ubuntu."
print_warning "You can choose exactly what you want to install."
echo ""

if ! ask_yes_no "Ready to begin?" "y"; then
    print_error "Setup cancelled."
    exit 0
fi

# ============================================================================
# BASE SYSTEM - Always installed
# ============================================================================
print_section "STEP 1: Installing Base System Packages"

print_info "Updating system packages..."
sudo apt update && sudo apt upgrade -y

print_info "Installing essential base tools..."
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
    zstd \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    unzip \
    zip \
    gpg \
    tree \
    mousepad \
    thunar

print_status "Base system packages installed! (Including mousepad and thunar)"

# ============================================================================
# AI TOOLS MENU
# ============================================================================
print_section "STEP 2: AI Tools Selection"

ai_options=(
    "Ollama + Qwen2.5 7B model (4.7GB download)"
    "Python AI Virtual Environment (PyTorch, Transformers, etc.)"
    "Heretic with fixed dependencies (huggingface-hub 0.24.0)"
    "llama.cpp (for GGUF model work)"
    "Text Generation WebUI (Oobabooga)"
    "Vector Databases (ChromaDB, Qdrant)"
    "LangChain & LlamaIndex"
    "Jupyter Lab & Data Science Stack"
)

echo "Select AI tools to install (space-separated numbers):"
selected_ai=()
for i in "${!ai_options[@]}"; do
    echo "  $((i+1)). ${ai_options[$i]}"
done
echo ""
read -p "Enter numbers (e.g., 1 2 3): " -a ai_choices

for choice in "${ai_choices[@]}"; do
    if [[ $choice =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#ai_options[@]})); then
        selected_ai+=($choice)
    fi
done

# Install selected AI tools
for choice in "${selected_ai[@]}"; do
    case $choice in
        1)
            print_info "Installing Ollama..."
            curl -fsSL https://ollama.com/install.sh | sh
            ollama serve > /dev/null 2>&1 &
            sleep 5
            print_info "Pulling Qwen2.5 7B model (this may take a while)..."
            ollama pull qwen2.5:7b-instruct-q4_k_m
            print_status "Ollama + Qwen model installed!"
            ;;
        2)
            print_info "Creating Python AI virtual environment..."
            python3 -m venv ~/ai-env
            source ~/ai-env/bin/activate
            pip install --upgrade pip
            pip install \
                torch \
                transformers \
                accelerate \
                bitsandbytes \
                ipython \
                sentencepiece \
                protobuf
            deactivate
            print_status "Python AI environment created at ~/ai-env!"
            ;;
        3)
            print_info "Installing Heretic with fixed dependencies..."
            
            # Create dedicated Heretic environment
            python3 -m venv ~/heretic-env
            source ~/heretic-env/bin/activate
            
            # Install specific compatible versions
            pip install --upgrade pip
            pip install "huggingface-hub[cli]==0.24.0"
            pip install transformers==4.44.2
            pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124
            pip install accelerate bitsandbytes
            pip install heretic-llm
            
            # Create download script
            cat > ~/download_model.py << 'EOF'
#!/usr/bin/env python3
from huggingface_hub import snapshot_download
import os
import time

model_id = "Qwen/Qwen2.5-7B-Instruct"
local_dir = os.path.expanduser("~/models/qwen2.5-7b")

print(f"📥 Downloading {model_id} to {local_dir}")
print("This will take several hours at 1MB/s...")

start_time = time.time()
snapshot_download(
    repo_id=model_id,
    local_dir=local_dir,
    local_dir_use_symlinks=False,
    resume_download=True,
    max_workers=4,
)
elapsed = time.time() - start_time
print(f"✅ Download complete in {elapsed/60:.1f} minutes!")
EOF
            chmod +x ~/download_model.py
            
            # Add alias
            echo "alias heretic-run='source ~/heretic-env/bin/activate && heretic --model ~/models/qwen2.5-7b --quantization bnb_4bit'" >> ~/.bashrc
            
            deactivate
            print_status "Heretic installed! Use 'python ~/download_model.py' to get the model"
            ;;
        4)
            print_info "Installing llama.cpp..."
            git clone https://github.com/ggerganov/llama.cpp ~/llama.cpp
            cd ~/llama.cpp
            make -j$(nproc)
            cd ~
            print_status "llama.cpp installed!"
            ;;
        5)
            print_info "Installing Text Generation WebUI..."
            git clone https://github.com/oobabooga/text-generation-webui ~/text-generation-webui
            cd ~/text-generation-webui
            ./start_linux.sh --listen > /dev/null 2>&1 &
            cd ~
            print_status "Text Generation WebUI installed!"
            ;;
        6)
            print_info "Installing vector databases..."
            source ~/ai-env/bin/activate 2>/dev/null || python3 -m venv ~/ai-env && source ~/ai-env/bin/activate
            pip install chromadb qdrant-client
            deactivate
            print_status "Vector database clients installed!"
            ;;
        7)
            print_info "Installing LangChain & LlamaIndex..."
            source ~/ai-env/bin/activate 2>/dev/null || python3 -m venv ~/ai-env && source ~/ai-env/bin/activate
            pip install langchain llama-index
            deactivate
            print_status "LangChain & LlamaIndex installed!"
            ;;
        8)
            print_info "Installing Jupyter Lab & Data Science stack..."
            source ~/ai-env/bin/activate 2>/dev/null || python3 -m venv ~/ai-env && source ~/ai-env/bin/activate
            pip install \
                jupyterlab \
                notebook \
                ipywidgets \
                matplotlib \
                seaborn \
                plotly \
                scikit-learn \
                pandas \
                numpy \
                scipy \
                tensorboard \
                datasets
            deactivate
            print_status "Data Science stack installed!"
            ;;
    esac
done

# ============================================================================
# DEVELOPMENT TOOLS MENU
# ============================================================================
print_section "STEP 3: Development Tools Selection"

dev_options=(
    "Node.js + npm + nvm (Node Version Manager)"
    "Global NPM tools (yarn, pm2, typescript, etc.)"
    "Docker + Docker Compose (latest)"
    "Docker development tools (hadolint, dive)"
    "Python version managers (pyenv, poetry)"
    "SDKMAN (Java, Maven, Gradle)"
    "GitHub CLI (gh)"
    "Database tools (PostgreSQL, Redis, MongoDB)"
)

echo "Select development tools to install (space-separated numbers):"
for i in "${!dev_options[@]}"; do
    echo "  $((i+1)). ${dev_options[$i]}"
done
echo ""
read -p "Enter numbers (e.g., 1 2 3): " -a dev_choices

for choice in "${dev_choices[@]}"; do
    case $choice in
        1)
            print_info "Installing nvm and Node.js LTS..."
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
            nvm install --lts
            nvm use --lts
            print_status "Node.js $(node -v) and npm $(npm -v) installed!"
            ;;
        2)
            print_info "Installing global NPM tools..."
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
            npm install -g \
                yarn \
                pnpm \
                ts-node \
                typescript \
                nodemon \
                pm2 \
                eslint \
                prettier \
                http-server \
                live-server
            print_status "Global NPM tools installed!"
            ;;
        3)
            print_info "Installing Docker..."
            for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
                sudo apt-get remove -y $pkg 2>/dev/null || true
            done
            
            sudo install -m 0755 -d /etc/apt/keyrings
            sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
            sudo chmod a+r /etc/apt/keyrings/docker.asc
            
            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
              $(. /etc/os-release && echo "$UBUNTU_CODENAME") stable" | \
              sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            sudo apt update
            sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
            sudo usermod -aG docker $USER
            
            print_info "Installing latest Docker Compose..."
            sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
            
            print_status "Docker and Docker Compose installed!"
            ;;
        4)
            print_info "Installing Docker development tools..."
            # hadolint
            sudo wget -O /bin/hadolint https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-x86_64
            sudo chmod +x /bin/hadolint
            
            # dive
            wget https://github.com/wagoodman/dive/releases/download/v0.12.0/dive_0.12.0_linux_amd64.deb
            sudo dpkg -i dive_*.deb
            rm dive_*.deb
            print_status "Docker development tools installed!"
            ;;
        5)
            print_info "Installing pyenv and poetry..."
            # pyenv
            curl https://pyenv.run | bash
            echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.bashrc
            echo 'command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.bashrc
            echo 'eval "$(pyenv init -)"' >> ~/.bashrc
            
            # poetry
            curl -sSL https://install.python-poetry.org | python3 -
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
            print_status "pyenv and poetry installed!"
            ;;
        6)
            print_info "Installing SDKMAN and Java..."
            curl -s "https://get.sdkman.io" | bash
            source "$HOME/.sdkman/bin/sdkman-init.sh"
            sdk install java 17.0.10-tem
            sdk install maven
            sdk install gradle
            print_status "SDKMAN, Java, Maven, Gradle installed!"
            ;;
        7)
            print_info "Installing GitHub CLI..."
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
            sudo apt update
            sudo apt install -y gh
            print_status "GitHub CLI installed!"
            ;;
        8)
            print_info "Installing databases..."
            # PostgreSQL
            sudo apt install -y postgresql postgresql-contrib
            sudo service postgresql start
            
            # Redis
            sudo apt install -y redis-server
            sudo service redis-server start
            
            # MongoDB
            wget -qO - https://www.mongodb.org/static/pgp/server-7.0.asc | sudo apt-key add -
            echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list
            sudo apt update
            sudo apt install -y mongodb-org
            
            print_status "Databases installed!"
            ;;
    esac
done

# ============================================================================
# TERMINAL & PRODUCTIVITY MENU
# ============================================================================
print_section "STEP 4: Terminal & Productivity Tools Selection"

terminal_options=(
    "Oh My Zsh with plugins (zsh-autosuggestions, syntax-highlighting)"
    "Advanced monitoring tools (btop, nvtop, glances)"
    "Git enhancements (lazygit, git-extras)"
    "Networking tools (httpie, jq, nmap)"
    "WSL performance tweaks"
)

echo "Select terminal & productivity tools to install (space-separated numbers):"
for i in "${!terminal_options[@]}"; do
    echo "  $((i+1)). ${terminal_options[$i]}"
done
echo ""
read -p "Enter numbers (e.g., 1 2 3): " -a term_choices

for choice in "${term_choices[@]}"; do
    case $choice in
        1)
            print_info "Installing Oh My Zsh..."
            sudo apt install -y zsh
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
            
            # Install plugins
            git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
            git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
            
            # Update .zshrc to enable plugins
            sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' ~/.zshrc
            
            # Set Zsh as default shell
            sudo chsh -s $(which zsh) $USER
            print_status "Oh My Zsh installed! Will be active after restart."
            ;;
        2)
            print_info "Installing monitoring tools..."
            sudo apt install -y \
                btop \
                nvtop \
                glances \
                iotop \
                iftop
            
            print_status "Monitoring tools installed!"
            ;;
        3)
            print_info "Installing Git enhancements..."
            sudo apt install -y git-extras
            
            # Install lazygit
            sudo add-apt-repository ppa:lazygit-team/release -y
            sudo apt update
            sudo apt install -y lazygit
            
            print_status "Git tools installed!"
            ;;
        4)
            print_info "Installing networking tools..."
            sudo apt install -y \
                httpie \
                jq \
                yq \
                nmap \
                netcat-traditional \
                tcpdump \
                wireshark-common
            
            print_status "Networking tools installed!"
            ;;
        5)
            print_info "Applying WSL performance tweaks..."
            
            # Create .wslconfig instructions
            cat > ~/WSL_SETUP.txt << 'EOF'
===============================================
WSL PERFORMANCE TWEAKS - READ THIS!
===============================================

1. Create a file at: C:\Users\<YourUsername>\.wslconfig
2. Add this content:

[wsl2]
memory=16GB
processors=8
swap=8GB
localhostForwarding=true

3. Run in PowerShell: wsl --shutdown
4. Restart WSL
===============================================
EOF
            
            # Add WSL-specific aliases
            cat >> ~/.bashrc << 'EOF'

# WSL specific aliases
alias wsl-restart='cd ~ && cmd.exe /c wsl --shutdown'
alias windows='cd /mnt/c/Users/$USER'
alias chrome="/mnt/c/Program\ Files/Google/Chrome/Application/chrome.exe"
alias code='cd $PWD && cmd.exe /c code .'
alias mousepad='mousepad'
alias thunar='thunar'
EOF
            
            print_status "WSL tweaks applied! Check ~/WSL_SETUP.txt for Windows-side config."
            ;;
    esac
done

# ============================================================================
# CREATE DIRECTORIES AND ALIASES
# ============================================================================
print_section "STEP 5: Finalizing Setup"

print_info "Creating project directories..."
mkdir -p ~/models
mkdir -p ~/projects
mkdir -p ~/downloads
mkdir -p ~/cache/huggingface
mkdir -p ~/docker

print_info "Setting up environment variables and aliases..."
cat >> ~/.bashrc << 'EOF'

# ===== AI ENVIRONMENT SETTINGS =====
export HF_HOME=~/cache/huggingface
export OLLAMA_MODELS=~/models/ollama

# AI Aliases
alias ai-env='source ~/ai-env/bin/activate'
alias ollama-run='ollama run qwen2.5:7b-instruct-q4_k_m'
alias models='cd ~/models'
alias projects='cd ~/projects'

# Memory monitoring
alias mem='free -h'
alias gpu='nvidia-smi'
alias top-ai='watch -n 2 nvidia-smi'

# Docker aliases
alias d='docker'
alias dc='docker-compose'
alias dps='docker ps'
alias di='docker images'

# Git aliases
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline --graph'

# GUI apps
alias edit='mousepad'
alias files='thunar'
EOF

# ============================================================================
# CREATE TEST SCRIPTS
# ============================================================================
print_info "Creating test scripts..."

# Python test script
cat > ~/test_ai.py << 'EOF'
#!/usr/bin/env python3
print("Testing AI environment...")
try:
    import torch
    print(f"✅ PyTorch {torch.__version__}")
    print(f"✅ CUDA available: {torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"✅ GPU: {torch.cuda.get_device_name(0)}")
    
    import transformers
    print(f"✅ Transformers {transformers.__version__}")
    
    import accelerate
    print(f"✅ Accelerate installed")
    
    print("\n🎉 AI environment is ready!")
except ImportError as e:
    print(f"❌ Error: {e}")
EOF
chmod +x ~/test_ai.py

# Docker test script
cat > ~/test_docker.sh << 'EOF'
#!/bin/bash
echo "Testing Docker installation..."
if command -v docker &> /dev/null; then
    echo "✅ Docker installed: $(docker --version)"
    echo "✅ Docker Compose: $(docker-compose --version 2>/dev/null || echo 'Not installed')"
else
    echo "❌ Docker not found"
fi
EOF
chmod +x ~/test_docker.sh

# ============================================================================
# FINAL SUMMARY
# ============================================================================
clear
print_section "🎉 INSTALLATION COMPLETE!"

echo -e "${GREEN}What was installed:${NC}"
for choice in "${selected_ai[@]}"; do
    echo "  ✓ ${ai_options[$((choice-1))]}"
done
for choice in "${dev_choices[@]}"; do
    echo "  ✓ ${dev_options[$((choice-1))]}"
done
for choice in "${term_choices[@]}"; do
    echo "  ✓ ${terminal_options[$((choice-1))]}"
done

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}Quick Start Commands:${NC}"
echo "  source ~/.bashrc     - Reload your shell configuration"
echo "  ai-env              - Activate Python AI environment"
echo "  ollama-run          - Run Qwen model with Ollama"
echo "  heretic-run         - Run Heretic (if installed)"
echo "  python ~/download_model.py - Download model for Heretic"
echo "  ~/test_ai.py        - Test AI environment"
echo "  ~/test_docker.sh    - Test Docker installation"
echo "  mem/gpu/top-ai      - Monitor system resources"
echo "  edit                - Open mousepad"
echo "  files               - Open thunar file manager"
echo ""
echo -e "${YELLOW}Important Notes:${NC}"
if [[ " ${term_choices[@]} " =~ " 1 " ]]; then
    echo "  • Zsh is now your default shell (restart terminal to activate)"
fi
if [[ " ${dev_choices[@]} " =~ " 3 " ]]; then
    echo "  • You need to log out and back in for Docker permissions to take effect"
    echo "    Or run: newgrp docker"
fi
if [[ -f ~/WSL_SETUP.txt ]]; then
    echo "  • Check ~/WSL_SETUP.txt for Windows-side WSL configuration"
fi
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}✅ Setup complete! Enjoy your WSL AI development environment!${NC}"
echo ""
