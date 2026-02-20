#!/bin/bash

# ============================================================================
# WSL2 Ultimate AI & Development Environment Setup Script
# Complete Version - Includes AI tools, Dev tools, Terminal enhancements,
# and Security/Pentesting tools (PentAGI, PentestAgent, HackerAI, HexStrike)
# All paths correctly set for Ollama integration
# ============================================================================

set -e  # Exit on error

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

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
        [[ $default == "y" ]] && read -p "$question [Y/n]: " answer || read -p "$question [y/N]: " answer
        answer=${answer:-$default}
        case $answer in [Yy]*) return 0;; [Nn]*) return 1;; *) echo "Please answer yes or no.";; esac
    done
}

# Welcome
clear
echo -e "${PURPLE}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║     WSL2 Ultimate AI & Development Environment Setup     ║"
echo "║                  COMPLETE VERSION                        ║"
echo "╚═══════════════════════════════════════════════════════════╝${NC}\n"

print_warning "This script will install various tools on your fresh WSL Ubuntu."
ask_yes_no "Ready to begin?" "y" || { print_error "Setup cancelled."; exit 0; }

# ============================================================================
# STEP 1: Base System Packages (always installed)
# ============================================================================
print_section "STEP 1: Installing Base System Packages"

print_info "Updating system packages..."
sudo apt update && sudo apt upgrade -y

print_info "Installing essential base tools..."
sudo apt install -y \
    python3-pip python3-venv python3-full git curl wget build-essential cmake \
    htop neofetch nano tmux zstd ca-certificates gnupg lsb-release \
    software-properties-common apt-transport-https unzip zip gpg tree \
    mousepad thunar

print_status "Base system packages installed (including mousepad, thunar)"

# ============================================================================
# STEP 2: AI Tools Selection
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
for i in "${!ai_options[@]}"; do echo "  $((i+1)). ${ai_options[$i]}"; done
echo ""
read -p "Enter numbers (e.g., 1 2 3): " -a ai_choices

selected_ai=()
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
            # Set Ollama models path
            mkdir -p ~/models/ollama
            echo "export OLLAMA_MODELS=~/models/ollama" >> ~/.bashrc
            ollama serve > /dev/null 2>&1 &
            sleep 5
            print_info "Pulling Qwen2.5 7B model (may take a while)..."
            ollama pull qwen2.5:7b-instruct-q4_k_m
            print_status "Ollama + Qwen model installed!"
            ;;
        2)
            print_info "Creating Python AI virtual environment..."
            python3 -m venv ~/ai-env
            source ~/ai-env/bin/activate
            pip install --upgrade pip
            pip install torch transformers accelerate bitsandbytes ipython sentencepiece protobuf
            deactivate
            print_status "AI environment created at ~/ai-env"
            ;;
        3)
            print_info "Installing Heretic with fixed dependencies..."
            python3 -m venv ~/heretic-env
            source ~/heretic-env/bin/activate
            pip install "huggingface-hub[cli]==0.24.0" transformers==4.44.2
            pip install torch --index-url https://download.pytorch.org/whl/cu124
            pip install accelerate bitsandbytes heretic-llm
            # Create model download script
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
            echo "alias heretic-run='source ~/heretic-env/bin/activate && heretic --model ~/models/qwen2.5-7b --quantization bnb_4bit'" >> ~/.bashrc
            deactivate
            print_status "Heretic installed. Run 'python ~/download_model.py' to download model, then 'heretic-run'"
            ;;
        4)
            print_info "Installing llama.cpp..."
            git clone https://github.com/ggerganov/llama.cpp ~/llama.cpp
            cd ~/llama.cpp
            make -j$(nproc)
            cd ~
            print_status "llama.cpp installed"
            ;;
        5)
            print_info "Installing Text Generation WebUI..."
            if [ -d ~/text-generation-webui ]; then
                cd ~/text-generation-webui && git pull
            else
                git clone https://github.com/oobabooga/text-generation-webui ~/text-generation-webui
            fi
            cd ~/text-generation-webui
            ./start_linux.sh --listen > /dev/null 2>&1 &
            cd ~
            print_status "Text Generation WebUI started"
            ;;
        6)
            print_info "Installing vector databases..."
            source ~/ai-env/bin/activate 2>/dev/null || python3 -m venv ~/ai-env && source ~/ai-env/bin/activate
            pip install chromadb qdrant-client
            deactivate
            print_status "Vector DB clients installed"
            ;;
        7)
            print_info "Installing LangChain & LlamaIndex..."
            source ~/ai-env/bin/activate 2>/dev/null || python3 -m venv ~/ai-env && source ~/ai-env/bin/activate
            pip install langchain llama-index
            deactivate
            print_status "LangChain & LlamaIndex installed"
            ;;
        8)
            print_info "Installing Jupyter Lab & Data Science stack..."
            source ~/ai-env/bin/activate 2>/dev/null || python3 -m venv ~/ai-env && source ~/ai-env/bin/activate
            pip install jupyterlab notebook ipywidgets matplotlib seaborn plotly scikit-learn pandas numpy scipy tensorboard datasets
            deactivate
            print_status "Data Science stack installed"
            ;;
    esac
done

# ============================================================================
# STEP 3: Development Tools Selection
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
for i in "${!dev_options[@]}"; do echo "  $((i+1)). ${dev_options[$i]}"; done
echo ""
read -p "Enter numbers (e.g., 1 2 3): " -a dev_choices

for choice in "${dev_choices[@]}"; do
    case $choice in
        1)
            print_info "Installing nvm and Node.js LTS..."
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
            nvm install --lts && nvm use --lts
            print_status "Node.js $(node -v) and npm $(npm -v) installed"
            ;;
        2)
            print_info "Installing global NPM tools..."
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
            npm install -g yarn pnpm ts-node typescript nodemon pm2 eslint prettier http-server live-server
            print_status "Global NPM tools installed"
            ;;
        3)
            print_info "Installing Docker..."
            for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
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
            print_status "Docker and Docker Compose installed (log out/in for group changes)"
            ;;
        4)
            print_info "Installing Docker development tools..."
            sudo wget -O /bin/hadolint https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-x86_64 && sudo chmod +x /bin/hadolint
            wget https://github.com/wagoodman/dive/releases/download/v0.12.0/dive_0.12.0_linux_amd64.deb && sudo dpkg -i dive_*.deb && rm dive_*.deb
            print_status "Docker dev tools installed"
            ;;
        5)
            print_info "Installing pyenv and poetry..."
            curl https://pyenv.run | bash
            echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.bashrc
            echo 'command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.bashrc
            echo 'eval "$(pyenv init -)"' >> ~/.bashrc
            curl -sSL https://install.python-poetry.org | python3 -
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
            print_status "pyenv and poetry installed"
            ;;
        6)
            print_info "Installing SDKMAN and Java..."
            curl -s "https://get.sdkman.io" | bash
            source "$HOME/.sdkman/bin/sdkman-init.sh"
            sdk install java 17.0.10-tem && sdk install maven && sdk install gradle
            print_status "SDKMAN, Java, Maven, Gradle installed"
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
            sudo apt install -y postgresql postgresql-contrib && sudo service postgresql start
            sudo apt install -y redis-server && sudo service redis-server start
            wget -qO - https://www.mongodb.org/static/pgp/server-7.0.asc | sudo apt-key add -
            echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list
            sudo apt update && sudo apt install -y mongodb-org
            print_status "Databases installed"
            ;;
    esac
done

# ============================================================================
# STEP 4: Terminal & Productivity Tools Selection
# ============================================================================
print_section "STEP 4: Terminal & Productivity Tools Selection"

term_options=(
    "Oh My Zsh with plugins (zsh-autosuggestions, syntax-highlighting)"
    "Advanced monitoring tools (btop, nvtop, glances)"
    "Git enhancements (lazygit, git-extras)"
    "Networking tools (httpie, jq, nmap)"
    "WSL performance tweaks"
)

echo "Select terminal & productivity tools to install (space-separated numbers):"
for i in "${!term_options[@]}"; do echo "  $((i+1)). ${term_options[$i]}"; done
echo ""
read -p "Enter numbers (e.g., 1 2 3): " -a term_choices

for choice in "${term_choices[@]}"; do
    case $choice in
        1)
            print_info "Installing Oh My Zsh..."
            sudo apt install -y zsh
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
            git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
            git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
            sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' ~/.zshrc
            sudo chsh -s $(which zsh) $USER
            print_status "Oh My Zsh installed (restart terminal to use)"
            ;;
        2)
            print_info "Installing monitoring tools..."
            sudo apt install -y btop nvtop glances iotop iftop
            print_status "Monitoring tools installed"
            ;;
        3)
            print_info "Installing Git enhancements..."
            sudo apt install -y git-extras
            sudo add-apt-repository ppa:lazygit-team/release -y && sudo apt update && sudo apt install -y lazygit
            print_status "Git tools installed"
            ;;
        4)
            print_info "Installing networking tools..."
            sudo apt install -y httpie jq yq nmap netcat-traditional tcpdump wireshark-common
            print_status "Networking tools installed"
            ;;
        5)
            print_info "Applying WSL performance tweaks..."
            cat > ~/WSL_SETUP.txt << 'EOF'
===============================================
WSL PERFORMANCE TWEAKS
===============================================
Create C:\Users\<YourUsername>\.wslconfig with:
[wsl2]
memory=16GB
processors=8
swap=8GB
localhostForwarding=true
Then in PowerShell: wsl --shutdown
===============================================
EOF
            cat >> ~/.bashrc << 'EOF'
# WSL specific aliases
alias wsl-restart='cd ~ && cmd.exe /c wsl --shutdown'
alias windows='cd /mnt/c/Users/$USER'
alias chrome="/mnt/c/Program\ Files/Google/Chrome/Application/chrome.exe"
alias code='cd $PWD && cmd.exe /c code .'
EOF
            print_status "WSL tweaks applied (see ~/WSL_SETUP.txt)"
            ;;
    esac
done

# ============================================================================
# STEP 5: Security & Pentesting Tools Selection
# ============================================================================
print_section "STEP 5: Security & Pentesting Tools Selection"

sec_options=(
    "PentAGI - Autonomous AI penetration testing (Docker + complex stack)"
    "PentestAgent - AI agent framework for black-box testing"
    "HackerAI - Web-based AI penetration testing assistant"
    "HexStrike AI - MCP server with 150+ security tools"
)

echo "Select security/pentesting tools to install (space-separated numbers):"
for i in "${!sec_options[@]}"; do echo "  $((i+1)). ${sec_options[$i]}"; done
echo ""
read -p "Enter numbers (e.g., 1 2 3): " -a sec_choices

for choice in "${sec_choices[@]}"; do
    case $choice in
        1)
            print_info "Installing PentAGI..."
            if ! command -v docker &> /dev/null; then
                print_warning "Docker not found. Please install Docker first (Dev Tools option 3)."
            else
                git clone https://github.com/vxcontrol/pentagi.git ~/pentagi
                cd ~/pentagi
                cp .env.example .env
                print_info "Edit ~/pentagi/.env to add API keys (OpenAI, Anthropic, etc.)"
                docker-compose up -d
                cd ~
                print_status "PentAGI installed! Web UI at http://localhost:8080"
                echo "alias pentagi='cd ~/pentagi && docker-compose up -d'" >> ~/.bashrc
            fi
            ;;
        2)
            print_info "Installing PentestAgent..."
            python_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
            if (( $(echo "$python_version < 3.10" | bc -l) )); then
                print_error "PentestAgent requires Python 3.10+. Current: $python_version"
            else
                git clone https://github.com/GH05TCREW/pentestagent.git ~/pentestagent
                cd ~/pentestagent
                if [[ -f "scripts/setup.sh" ]]; then
                    chmod +x scripts/setup.sh && ./scripts/setup.sh
                else
                    python3 -m venv venv
                    source venv/bin/activate
                    pip install -e ".[all]"
                    playwright install chromium
                    deactivate
                fi
                cp .env.example .env
                echo "alias pentestagent='cd ~/pentestagent && source venv/bin/activate && pentestagent'" >> ~/.bashrc
                cd ~
                print_status "PentestAgent installed. Edit ~/pentestagent/.env and run 'pentestagent'"
            fi
            ;;
        3)
            print_info "Installing HackerAI..."
            if ! command -v node &> /dev/null; then
                print_warning "Node.js not found. Please install Node.js first (Dev Tools option 1)."
            else
                command -v pnpm &> /dev/null || npm install -g pnpm
                git clone https://github.com/hackerai-tech/hackerai.git ~/hackerai
                cd ~/hackerai
                pnpm install
                pnpm run setup
                print_info "HackerAI requires multiple API keys and services."
                print_info "See https://github.com/hackerai-tech/hackerai for setup."
                echo "alias hackerai='cd ~/hackerai && pnpm run dev'" >> ~/.bashrc
                cd ~
                print_status "HackerAI installed. Run 'hackerai' after configuring .env"
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
            print_info "Installing security tools (this may take a while)..."
            sudo apt update
            sudo apt install -y nmap masscan rustscan amass subfinder nuclei fierce dnsenum \
                autorecon theharvester responder netexec enum4linux-ng gobuster feroxbuster \
                dirsearch ffuf dirb httpx katana nikto sqlmap wpscan arjun paramspider dalfox \
                wafw00f hydra john hashcat medusa patator evil-winrm gdb radare2 binwalk \
                checksec foremost steghide exiftool chromium-browser
            if command -v go &> /dev/null; then
                go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest
                go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest
            fi
            cat > ~/hexstrike-ai/start.sh << 'EOF'
#!/bin/bash
cd ~/hexstrike-ai
source hexstrike-env/bin/activate
python3 hexstrike_server.py
EOF
            chmod +x ~/hexstrike-ai/start.sh
            echo "alias hexstrike='~/hexstrike-ai/start.sh'" >> ~/.bashrc
            cd ~
            print_status "HexStrike AI installed. Run 'hexstrike' to start server."
            ;;
    esac
done

# ============================================================================
# STEP 6: Finalizing Setup - Create Directories, Aliases, and Test Scripts
# ============================================================================
print_section "STEP 6: Finalizing Setup"

print_info "Creating project directories..."
mkdir -p ~/models ~/projects ~/downloads ~/cache/huggingface ~/docker
echo "export HF_HOME=~/cache/huggingface" >> ~/.bashrc

# Add common aliases (if not already added)
cat >> ~/.bashrc << 'EOF'

# ===== AI Environment Aliases =====
alias ai-env='source ~/ai-env/bin/activate'
alias ollama-run='ollama run qwen2.5:7b-instruct-q4_k_m'
alias models='cd ~/models'
alias projects='cd ~/projects'

# ===== System Monitoring =====
alias mem='free -h'
alias gpu='nvidia-smi'
alias top-ai='watch -n 2 nvidia-smi'

# ===== Docker =====
alias d='docker'
alias dc='docker-compose'
alias dps='docker ps'
alias di='docker images'

# ===== Git =====
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline --graph'

# ===== GUI Apps =====
alias edit='mousepad'
alias files='thunar'
EOF

# Create test script
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
    print("\n🎉 AI environment is ready!")
except ImportError as e:
    print(f"❌ Error: {e}")
EOF
chmod +x ~/test_ai.py

# ============================================================================
# FINAL SUMMARY
# ============================================================================
clear
print_section "🎉 INSTALLATION COMPLETE!"

echo -e "${GREEN}Installed components:${NC}"
for c in "${selected_ai[@]}"; do echo "  ✓ ${ai_options[$((c-1))]}"; done
for c in "${dev_choices[@]}"; do echo "  ✓ ${dev_options[$((c-1))]}"; done
for c in "${term_choices[@]}"; do echo "  ✓ ${term_options[$((c-1))]}"; done
for c in "${sec_choices[@]}"; do echo "  ✓ ${sec_options[$((c-1))]}"; done

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}Quick Start Commands:${NC}"
echo "  source ~/.bashrc           - Reload your shell configuration"
echo "  ai-env                     - Activate Python AI environment"
echo "  ollama-run                 - Run Qwen model with Ollama"
echo "  python ~/download_model.py - Download model for Heretic (if installed)"
echo "  heretic-run                 - Run Heretic (after model download)"
echo "  pentestagent                - Run PentestAgent (if installed)"
echo "  pentagi                     - Start PentAGI (if installed)"
echo "  hackerai                    - Run HackerAI dev server (if installed)"
echo "  hexstrike                   - Start HexStrike server (if installed)"
echo "  ~/test_ai.py                - Test AI environment"
echo "  mem/gpu/top-ai              - Monitor resources"
echo "  edit/files                   - Open mousepad/thunar"
echo ""
echo -e "${YELLOW}Important Notes:${NC}"
if [[ " ${dev_choices[@]} " =~ " 3 " ]]; then
    echo "  • Docker: log out and back in, or run 'newgrp docker'"
fi
if [[ -f ~/WSL_SETUP.txt ]]; then
    echo "  • See ~/WSL_SETUP.txt for Windows-side WSL performance config"
fi
for c in "${sec_choices[@]}"; do
    case $c in
        1) echo "  • PentAGI: edit ~/pentagi/.env with API keys";;
        2) echo "  • PentestAgent: edit ~/pentestagent/.env with API keys";;
        3) echo "  • HackerAI: follow setup guide at https://github.com/hackerai-tech/hackerai";;
        4) echo "  • HexStrike: configure AI clients per their docs";;
    esac
done
echo ""
echo -e "${GREEN}✅ Setup complete! Enjoy your WSL AI development environment!${NC}"
