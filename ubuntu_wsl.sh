#!/bin/bash

# ============================================================================
# WSL2 Ultimate AI & Development Environment – COMPLETE EDITION
# - Smart Ollama installer (checks for updates)
# - Model selection menu for uncensored models
# - All dev tools, terminal tools, security tools
# - Heretic optional
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
echo "║     WSL2 Ultimate AI & Development Environment           ║"
echo "║              COMPLETE EDITION with Model Selector        ║"
echo "╚═══════════════════════════════════════════════════════════╝${NC}\n"

# ============================================================================
# PART 1: BASE SYSTEM
# ============================================================================
print_section "STEP 1: Installing Base System Packages"

print_info "Updating system packages..."
sudo apt update || true

print_info "Installing essential base tools..."
sudo apt install -y \
    python3-pip python3-venv python3-full git curl wget build-essential cmake \
    htop neofetch nano tmux zstd ca-certificates gnupg lsb-release \
    software-properties-common apt-transport-https unzip zip gpg tree \
    mousepad thunar bc

print_status "Base system packages installed"

# ============================================================================
# PART 2: OLLAMA + MODEL SELECTOR (SMART)
# ============================================================================
print_section "STEP 2: Ollama + Uncensored Model Selector"

# Check/Install Ollama
if command -v ollama &> /dev/null; then
    print_status "Ollama is already installed"
    CURRENT_VERSION=$(ollama --version 2>/dev/null | head -1 | cut -d' ' -f2 || echo "unknown")
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

# Show installed models
echo ""
print_info "Currently installed models:"
ollama list 2>/dev/null || echo "  No models installed yet."

# Model selection menu
echo ""
echo -e "${CYAN}Available abliterated (uncensored) models:${NC}"
echo "  1. huihui_ai/qwen2.5-abliterate:7b    (7B, ~4.7GB)  – BEST FOR RTX 3060"
echo "  2. huihui_ai/qwen2.5-abliterate:1.5b  (1.5B, ~1.1GB) – Faster, less capable"
echo "  3. huihui_ai/qwen2.5-abliterate:0.5b  (0.5B, ~398MB) – Tiny, for testing"
echo "  4. huihui_ai/qwen2.5-abliterate:14b   (14B, ~9.0GB)  – Bigger, may be slow"
echo "  5. huihui_ai/qwen2.5-vl-abliterated:7b (7B, ~6.0GB)  – Vision model"
echo "  6. Skip downloading any model now"
echo "  7. Enter custom model name"
echo ""

read -p "Choose model to download [1-7]: " model_choice

case $model_choice in
    1) MODEL="huihui_ai/qwen2.5-abliterate:7b" ;;
    2) MODEL="huihui_ai/qwen2.5-abliterate:1.5b" ;;
    3) MODEL="huihui_ai/qwen2.5-abliterate:0.5b" ;;
    4) MODEL="huihui_ai/qwen2.5-abliterate:14b" ;;
    5) MODEL="huihui_ai/qwen2.5-vl-abliterated:7b" ;;
    6) MODEL="" ;;
    7) 
        echo "Browse models at: https://ollama.com/huihui_ai"
        read -p "Enter full model name: " CUSTOM_MODEL
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
    
    if ollama list 2>/dev/null | grep -q "$MODEL"; then
        print_warning "Model already exists. Checking for update..."
        ollama pull "$MODEL"
    else
        ollama pull "$MODEL"
    fi
    print_status "Model ready!"
    
    # Add alias
    MODEL_SHORT=$(echo "$MODEL" | cut -d'/' -f2 | tr ':' '-')
    echo "alias $MODEL_SHORT='ollama run $MODEL'" >> ~/.bashrc.tmp
    echo "alias uncensored='ollama run $MODEL'" >> ~/.bashrc.tmp
fi

# ============================================================================
# PART 3: AI TOOLS (excluding Ollama since we already did that)
# ============================================================================
print_section "STEP 3: Additional AI Tools"

ai_options=(
    "Python AI Virtual Environment (PyTorch, Transformers)"
    "Heretic with fixed dependencies (model ablator)"
    "llama.cpp (for GGUF model work)"
    "Text Generation WebUI (Oobabooga)"
    "Vector Databases (ChromaDB, Qdrant)"
    "LangChain & LlamaIndex"
    "Jupyter Lab & Data Science Stack"
    "Skip all additional AI tools"
)

echo "Select additional AI tools to install (space-separated numbers):"
for i in "${!ai_options[@]}"; do
    echo "  $((i+1)). ${ai_options[$i]}"
done
echo ""
read -p "Enter numbers (e.g., 1 2 3): " -a ai_choices

for choice in "${ai_choices[@]}"; do
    case $choice in
        1)
            print_info "Creating Python AI virtual environment..."
            python3 -m venv ~/ai-env
            source ~/ai-env/bin/activate
            pip install --upgrade pip
            pip install torch transformers accelerate bitsandbytes ipython sentencepiece protobuf
            deactivate
            print_status "AI environment created at ~/ai-env"
            ;;
        2)
            print_info "Installing Heretic..."
            python3 -m venv ~/heretic-env
            source ~/heretic-env/bin/activate
            pip install "huggingface-hub==0.24.0" "transformers==4.44.2"
            pip install torch --index-url https://download.pytorch.org/whl/cu124
            pip install accelerate bitsandbytes heretic-llm
            cat > ~/download_model.py << 'EOF'
from huggingface_hub import snapshot_download
import os
snapshot_download(
    repo_id="Qwen/Qwen2.5-7B-Instruct",
    local_dir=os.path.expanduser("~/models/qwen2.5-7b"),
    local_dir_use_symlinks=False,
    resume_download=True,
    max_workers=4
)
EOF
            chmod +x ~/download_model.py
            echo "alias heretic-run='source ~/heretic-env/bin/activate && heretic --model ~/models/qwen2.5-7b --quantization bnb_4bit'" >> ~/.bashrc.tmp
            deactivate
            print_status "Heretic installed"
            ;;
        3)
            print_info "Installing llama.cpp..."
            git clone https://github.com/ggerganov/llama.cpp ~/llama.cpp
            cd ~/llama.cpp
            make -j$(nproc)
            cd ~
            print_status "llama.cpp installed"
            ;;
        4)
            print_info "Installing Text Generation WebUI..."
            if [ -d ~/text-generation-webui ]; then
                cd ~/text-generation-webui && git pull
            else
                git clone https://github.com/oobabooga/text-generation-webui ~/text-generation-webui
            fi
            print_status "Text Generation WebUI cloned"
            ;;
        5)
            print_info "Installing vector databases..."
            python3 -m venv ~/ai-env 2>/dev/null || true
            source ~/ai-env/bin/activate 2>/dev/null || true
            pip install chromadb qdrant-client
            deactivate
            print_status "Vector DB clients installed"
            ;;
        6)
            print_info "Installing LangChain & LlamaIndex..."
            python3 -m venv ~/ai-env 2>/dev/null || true
            source ~/ai-env/bin/activate 2>/dev/null || true
            pip install langchain llama-index
            deactivate
            print_status "LangChain & LlamaIndex installed"
            ;;
        7)
            print_info "Installing Jupyter Lab & Data Science..."
            python3 -m venv ~/ai-env 2>/dev/null || true
            source ~/ai-env/bin/activate 2>/dev/null || true
            pip install jupyterlab notebook ipywidgets matplotlib seaborn plotly scikit-learn pandas numpy scipy tensorboard datasets
            deactivate
            print_status "Data Science stack installed"
            ;;
        8)
            print_info "Skipping additional AI tools"
            ;;
    esac
done

# ============================================================================
# PART 4: DEVELOPMENT TOOLS
# ============================================================================
print_section "STEP 4: Development Tools"

dev_options=(
    "Node.js + npm + nvm"
    "Global NPM tools (yarn, pm2, typescript)"
    "Docker + Docker Compose"
    "Docker dev tools (hadolint, dive)"
    "pyenv + poetry"
    "SDKMAN (Java, Maven, Gradle)"
    "GitHub CLI (gh)"
    "Databases (PostgreSQL, Redis, MongoDB)"
    "Skip all development tools"
)

echo "Select development tools to install (space-separated numbers):"
for i in "${!dev_options[@]}"; do
    echo "  $((i+1)). ${dev_options[$i]}"
done
echo ""
read -p "Enter numbers: " -a dev_choices

for choice in "${dev_choices[@]}"; do
    case $choice in
        1)
            print_info "Installing nvm and Node.js LTS..."
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
            nvm install --lts && nvm use --lts
            print_status "Node.js installed"
            ;;
        2)
            print_info "Installing global NPM tools..."
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
            npm install -g yarn pnpm ts-node typescript nodemon pm2 eslint prettier
            print_status "NPM tools installed"
            ;;
        3)
            print_info "Installing Docker..."
            for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
                sudo apt-get remove -y $pkg 2>/dev/null || true
            done
            sudo install -m 0755 -d /etc/apt/keyrings
            sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
            sudo chmod a+r /etc/apt/keyrings/docker.asc
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt update
            sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
            sudo usermod -aG docker $USER
            sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
            print_status "Docker installed"
            ;;
        4)
            print_info "Installing Docker dev tools..."
            sudo wget -O /bin/hadolint https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-x86_64 && sudo chmod +x /bin/hadolint
            wget https://github.com/wagoodman/dive/releases/download/v0.12.0/dive_0.12.0_linux_amd64.deb && sudo dpkg -i dive_*.deb && rm dive_*.deb
            print_status "Docker dev tools installed"
            ;;
        5)
            print_info "Installing pyenv and poetry..."
            curl https://pyenv.run | bash
            echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.bashrc.tmp
            echo 'command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.bashrc.tmp
            echo 'eval "$(pyenv init -)"' >> ~/.bashrc.tmp
            curl -sSL https://install.python-poetry.org | python3 -
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc.tmp
            print_status "pyenv and poetry installed"
            ;;
        6)
            print_info "Installing SDKMAN and Java..."
            curl -s "https://get.sdkman.io" | bash
            source "$HOME/.sdkman/bin/sdkman-init.sh" 2>/dev/null || true
            print_status "SDKMAN installed (run 'sdk install java' manually)"
            ;;
        7)
            print_info "Installing GitHub CLI..."
            curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
            sudo apt update && sudo apt install -y gh
            print_status "GitHub CLI installed"
            ;;
        8)
            print_info "Installing databases..."
            sudo apt install -y postgresql postgresql-contrib && sudo systemctl start postgresql
            sudo apt install -y redis-server && sudo systemctl start redis-server
            wget -qO - https://www.mongodb.org/static/pgp/server-7.0.asc | sudo apt-key add - 2>/dev/null || true
            echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list
            sudo apt update && sudo apt install -y mongodb-org || true
            print_status "Databases installed"
            ;;
        9)
            print_info "Skipping development tools"
            ;;
    esac
done

# ============================================================================
# PART 5: TERMINAL & PRODUCTIVITY TOOLS
# ============================================================================
print_section "STEP 5: Terminal & Productivity Tools"

term_options=(
    "Oh My Zsh with plugins"
    "Monitoring tools (btop, nvtop, glances)"
    "Git enhancements (lazygit, git-extras)"
    "Networking tools (httpie, jq, nmap)"
    "WSL performance tweaks"
    "Skip all terminal tools"
)

echo "Select terminal tools to install (space-separated numbers):"
for i in "${!term_options[@]}"; do
    echo "  $((i+1)). ${term_options[$i]}"
done
echo ""
read -p "Enter numbers: " -a term_choices

for choice in "${term_choices[@]}"; do
    case $choice in
        1)
            print_info "Installing Oh My Zsh..."
            sudo apt install -y zsh
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
            git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions 2>/dev/null || true
            git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting 2>/dev/null || true
            sudo chsh -s $(which zsh) $USER 2>/dev/null || true
            print_status "Oh My Zsh installed"
            ;;
        2)
            print_info "Installing monitoring tools..."
            sudo apt install -y btop nvtop glances iotop iftop
            print_status "Monitoring tools installed"
            ;;
        3)
            print_info "Installing Git enhancements..."
            sudo apt install -y git-extras
            LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
            curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
            tar xf lazygit.tar.gz lazygit
            sudo install lazygit /usr/local/bin
            rm lazygit lazygit.tar.gz
            print_status "Git tools installed"
            ;;
        4)
            print_info "Installing networking tools..."
            sudo apt install -y httpie jq yq nmap netcat-traditional tcpdump
            print_status "Networking tools installed"
            ;;
        5)
            print_info "Applying WSL tweaks..."
            cat >> ~/.bashrc.tmp << 'EOF'
alias wsl-restart='cd ~ && cmd.exe /c wsl --shutdown'
alias windows='cd /mnt/c/Users/$USER'
alias chrome="/mnt/c/Program\ Files/Google/Chrome/Application/chrome.exe"
alias code='cd $PWD && cmd.exe /c code .'
EOF
            print_status "WSL aliases added"
            ;;
        6)
            print_info "Skipping terminal tools"
            ;;
    esac
done

# ============================================================================
# PART 6: SECURITY & PENTESTING TOOLS
# ============================================================================
print_section "STEP 6: Security & Pentesting Tools"

sec_options=(
    "PentAGI (Docker-based)"
    "PentestAgent (Python 3.10+)"
    "HackerAI (Node.js)"
    "HexStrike AI (150+ tools)"
    "Skip all security tools"
)

echo "Select security tools to install (space-separated numbers):"
for i in "${!sec_options[@]}"; do
    echo "  $((i+1)). ${sec_options[$i]}"
done
echo ""
read -p "Enter numbers: " -a sec_choices

for choice in "${sec_choices[@]}"; do
    case $choice in
        1)
            print_info "Installing PentAGI..."
            if command -v docker &> /dev/null; then
                git clone https://github.com/vxcontrol/pentagi.git ~/pentagi
                cd ~/pentagi
                cp .env.example .env
                echo "Edit ~/pentagi/.env with your API keys"
                docker-compose up -d
                cd ~
                echo "alias pentagi='cd ~/pentagi && docker-compose up -d'" >> ~/.bashrc.tmp
                print_status "PentAGI started at http://localhost:8080"
            else
                print_warning "Docker not installed. Install Dev Tools option 3 first."
            fi
            ;;
        2)
            print_info "Installing PentestAgent..."
            python_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
            if (( $(echo "$python_version < 3.10" | bc -l) )); then
                print_error "PentestAgent requires Python 3.10+"
            else
                git clone https://github.com/GH05TCREW/pentestagent.git ~/pentestagent
                cd ~/pentestagent
                python3 -m venv venv
                source venv/bin/activate
                pip install -e ".[all]"
                playwright install chromium
                deactivate
                cp .env.example .env
                echo "alias pentestagent='cd ~/pentestagent && source venv/bin/activate && pentestagent'" >> ~/.bashrc.tmp
                cd ~
                print_status "PentestAgent installed"
            fi
            ;;
        3)
            print_info "Installing HackerAI..."
            if command -v node &> /dev/null; then
                command -v pnpm &> /dev/null || npm install -g pnpm
                git clone https://github.com/hackerai-tech/hackerai.git ~/hackerai
                cd ~/hackerai
                pnpm install
                pnpm run setup
                echo "alias hackerai='cd ~/hackerai && pnpm run dev'" >> ~/.bashrc.tmp
                cd ~
                print_status "HackerAI installed"
            else
                print_warning "Node.js not installed"
            fi
            ;;
        4)
            print_info "Installing HexStrike AI..."
            git clone https://github.com/0x4m4/hexstrike-ai.git ~/hexstrike-ai
            cd ~/hexstrike-ai
            python3 -m venv hexstrike-env
            source hexstrike-env/bin/activate
            pip install -r requirements.txt
            deactivate
            sudo apt install -y nmap masscan rustscan amass subfinder nuclei fierce dnsenum \
                autorecon theharvester responder netexec enum4linux-ng gobuster feroxbuster \
                dirsearch ffuf dirb httpx katana nikto sqlmap wpscan arjun paramspider dalfox \
                wafw00f hydra john hashcat medusa patator evil-winrm gdb radare2 binwalk \
                checksec foremost steghide exiftool chromium-browser 2>/dev/null || true
            cat > ~/hexstrike-ai/start.sh << 'EOF'
#!/bin/bash
cd ~/hexstrike-ai
source hexstrike-env/bin/activate
python3 hexstrike_server.py
EOF
            chmod +x ~/hexstrike-ai/start.sh
            echo "alias hexstrike='~/hexstrike-ai/start.sh'" >> ~/.bashrc.tmp
            cd ~
            print_status "HexStrike AI installed"
            ;;
        5)
            print_info "Skipping security tools"
            ;;
    esac
done

# ============================================================================
# PART 7: FINAL CLEANUP
# ============================================================================
print_section "STEP 7: Finalizing Setup"

# Create directories
mkdir -p ~/models ~/projects ~/downloads ~/cache/huggingface

# Merge temporary bashrc additions
if [ -f ~/.bashrc.tmp ]; then
    cat ~/.bashrc.tmp >> ~/.bashrc
    rm ~/.bashrc.tmp
fi

# Add common aliases if not already present
cat >> ~/.bashrc << 'EOF'
export HF_HOME=~/cache/huggingface
alias mem='free -h'
alias gpu='nvidia-smi'
alias top-ai='watch -n 2 nvidia-smi'
alias d='docker'
alias dc='docker-compose'
alias dps='docker ps'
alias di='docker images'
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline --graph'
alias edit='mousepad'
alias files='thunar'
EOF

# Create test script
cat > ~/test_env.py << 'EOF'
#!/usr/bin/env python3
print("Testing environment...")
try:
    import torch
    print(f"✅ PyTorch {torch.__version__}")
    print(f"✅ CUDA available: {torch.cuda.is_available()}")
except: print("⚠️ PyTorch not installed")
try:
    import transformers
    print(f"✅ Transformers {transformers.__version__}")
except: print("⚠️ Transformers not installed")
print("\n✅ Environment check complete!")
EOF
chmod +x ~/test_env.py

# ============================================================================
# FINAL SUMMARY
# ============================================================================
clear
print_section "🎉 INSTALLATION COMPLETE!"

echo -e "${GREEN}Your environment is ready!${NC}\n"

echo -e "${YELLOW}📋 Quick Commands:${NC}"
if [[ -n "$MODEL" ]]; then
    echo "  uncensored              - Chat with $MODEL"
fi
echo "  python3 ~/test_env.py    - Test Python environment"
echo "  ai-env                   - Activate AI virtual env (if installed)"
echo "  heretic-run              - Run Heretic (if installed)"
echo "  ollama list              - See all models"
echo ""

echo -e "${YELLOW}📦 Installed Components:${NC}"
[[ -n "$MODEL" ]] && echo "  • Ollama model: $MODEL"
[[ -d ~/ai-env ]] && echo "  • AI Python environment"
[[ -d ~/heretic-env ]] && echo "  • Heretic (model ablator)"
[[ -d ~/llama.cpp ]] && echo "  • llama.cpp"
[[ -d ~/text-generation-webui ]] && echo "  • Text Generation WebUI"
[[ -d ~/pentagi ]] && echo "  • PentAGI"
[[ -d ~/pentestagent ]] && echo "  • PentestAgent"
[[ -d ~/hackerai ]] && echo "  • HackerAI"
[[ -d ~/hexstrike-ai ]] && echo "  • HexStrike AI"

echo ""
echo -e "${GREEN}Enjoy your complete WSL AI development environment! 🚀${NC}"
