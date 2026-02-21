#!/bin/bash
# smart-local-llm.sh - Smart setup (skip/reinstall only)
# Run this anytime - it checks what's installed and asks before reinstalling

set -euo pipefail
trap 'echo -e "${RED}Error on line $LINENO${NC}"' ERR

MODELS_DIR="$HOME/local-llm-models"
BIN_DIR="$HOME/.local/bin"
LOG_FILE="$HOME/local-llm-setup-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

exec > >(tee -a "$LOG_FILE") 2>&1

print_step() { echo -e "\n${BLUE}🔧 $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_info() { echo -e "${CYAN}ℹ️ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️ $1${NC}"; }

# ------------------------------------------------------------
#  Check what's already installed
# ------------------------------------------------------------
check_existing() {
    print_step "Checking existing installations..."
    
    if command -v ollama &>/dev/null; then
        OLLAMA_EXISTS=true
        OLLAMA_VERSION=$(ollama --version 2>/dev/null | head -n1)
        print_success "Ollama already installed: $OLLAMA_VERSION"
    else
        OLLAMA_EXISTS=false
        print_info "Ollama not found"
    fi
    
    if systemctl is-active --quiet ollama 2>/dev/null; then
        OLLAMA_RUNNING=true
    else
        OLLAMA_RUNNING=false
    fi
    
    if [ -f "$BIN_DIR/llama-run" ] || [ -f "$BIN_DIR/main" ]; then
        LLAMACPP_EXISTS=true
        print_success "llama.cpp already installed"
    else
        LLAMACPP_EXISTS=false
        print_info "llama.cpp not found"
    fi
    
    if [ -f "$HOME/.local_llm_aliases" ]; then
        ALIASES_EXIST=true
        print_success "LLM aliases already configured"
    else
        ALIASES_EXIST=false
        print_info "LLM aliases not found"
    fi
    echo ""
}

# ------------------------------------------------------------
#  Ask user: skip or reinstall?
# ------------------------------------------------------------
ask_reinstall() {
    local component=$1
    echo -e "${YELLOW}⚠️  $component is already installed.${NC}"
    echo "   [s] Skip (keep current)"
    echo "   [r] Reinstall fresh"
    read -p "Choice [s/r]: " choice
    case $choice in
        r|R) return 0 ;;   # reinstall
        *) return 1 ;;     # skip
    esac
}

# ------------------------------------------------------------
#  Create directories
# ------------------------------------------------------------
create_dirs() {
    print_step "Setting up directories..."
    mkdir -p "$MODELS_DIR"/{ollama,gguf}
    mkdir -p "$BIN_DIR"
    print_success "Directories ready"
}

# ------------------------------------------------------------
#  Configure Ollama service (local only)
# ------------------------------------------------------------
configure_ollama_service() {
    print_step "Configuring Ollama for local-only use..."
    sudo systemctl stop ollama 2>/dev/null || true
    sudo mkdir -p /etc/ollama
    sudo tee /etc/ollama/config.json >/dev/null <<EOF
{
    "disable_telemetry": true,
    "disable_update_check": true,
    "models_dir": "$MODELS_DIR/ollama"
}
EOF
    sudo tee /etc/systemd/system/ollama.service >/dev/null <<EOF
[Unit]
Description=Ollama - Local Only
After=network.target
[Service]
ExecStart=/usr/local/bin/ollama serve
User=$USER
Group=$USER
Restart=always
Environment="OLLAMA_HOST=127.0.0.1"
Environment="OLLAMA_MODELS=$MODELS_DIR/ollama"
Environment="OLLAMA_DISABLE_TELEMETRY=1"
[Install]
WantedBy=default.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable ollama
    sudo systemctl start ollama
    print_success "Ollama service configured"
}

# ------------------------------------------------------------
#  Install / reinstall Ollama
# ------------------------------------------------------------
install_ollama() {
    print_step "Setting up Ollama..."
    
    local should_configure=false
    
    if [ "$OLLAMA_EXISTS" = true ]; then
        ask_reinstall "Ollama"
        local choice=$?
        if [ $choice -eq 0 ]; then
            print_info "Reinstalling Ollama..."
            curl -fsSL https://ollama.com/install.sh | sh
            should_configure=true
        else
            print_info "Keeping existing Ollama"
            if [ "$OLLAMA_RUNNING" = false ]; then
                print_warning "Ollama is not running. Start it? (y/n)"
                read -r start_ollama
                if [[ "$start_ollama" =~ ^[Yy]$ ]]; then
                    sudo systemctl start ollama
                    print_success "Ollama started"
                fi
            fi
            # Ask if they want to reconfigure service
            echo -e "${YELLOW}Reconfigure service for local-only mode? (y/n)${NC}"
            read -r reconfigure
            if [[ "$reconfigure" =~ ^[Yy]$ ]]; then
                configure_ollama_service
            fi
        fi
    else
        print_info "Installing Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
        should_configure=true
    fi
    
    if [ "$should_configure" = true ]; then
        configure_ollama_service
    fi
}

# ------------------------------------------------------------
#  Install / reinstall llama.cpp
# ------------------------------------------------------------
install_llamacpp() {
    print_step "Setting up llama.cpp..."
    
    if [ "$LLAMACPP_EXISTS" = true ]; then
        ask_reinstall "llama.cpp"
        local choice=$?
        if [ $choice -eq 0 ]; then
            print_info "Reinstalling llama.cpp..."
            cd /tmp
            rm -rf llama.cpp
            git clone https://github.com/ggerganov/llama.cpp.git
            cd llama.cpp
            make clean
            make -j$(nproc)
            cp main server "$BIN_DIR/" 2>/dev/null || true
            ln -sf "$BIN_DIR/main" "$BIN_DIR/llama-run" 2>/dev/null || true
            ln -sf "$BIN_DIR/server" "$BIN_DIR/llama-serve" 2>/dev/null || true
            cd ~
            print_success "llama.cpp reinstalled"
        else
            print_info "Keeping existing llama.cpp installation"
        fi
    else
        print_info "Installing llama.cpp..."
        cd /tmp
        git clone https://github.com/ggerganov/llama.cpp.git
        cd llama.cpp
        make -j$(nproc)
        cp main server "$BIN_DIR/" 2>/dev/null || true
        ln -sf "$BIN_DIR/main" "$BIN_DIR/llama-run"
        ln -sf "$BIN_DIR/server" "$BIN_DIR/llama-serve"
        cd ~
        print_success "llama.cpp installed"
    fi
}

# ------------------------------------------------------------
#  Create runner scripts
# ------------------------------------------------------------
create_runners() {
    print_step "Setting up model runners..."
    
    cat > "$BIN_DIR/run-gguf" << 'EOF'
#!/bin/bash
MODEL_DIR="$HOME/local-llm-models/gguf"
BIN_DIR="$HOME/.local/bin"
if [ $# -lt 1 ]; then
    echo "Usage: run-gguf <model-file> [prompt]"
    echo ""
    echo "Available models:"
    ls -1 "$MODEL_DIR"/*.gguf 2>/dev/null | xargs -n1 basename || echo "No models found in $MODEL_DIR"
    exit 1
fi
MODEL="$MODEL_DIR/$1"
if [ ! -f "$MODEL" ]; then
    echo "Model not found: $MODEL"
    exit 1
fi
PROMPT="${2:-Hello, how are you?}"
echo "🚀 Running $1 locally..."
"$BIN_DIR/llama-run" -m "$MODEL" -p "$PROMPT" -n 512 -t 4
EOF
    
    cat > "$BIN_DIR/local-models-info" << 'EOF'
#!/bin/bash
echo "📊 LOCAL MODELS STATUS"
echo "======================"
echo ""
echo "🦙 Ollama models:"
if command -v ollama &> /dev/null; then
    ollama list 2>/dev/null || echo "  No Ollama models found"
else
    echo "  Ollama not installed"
fi
echo ""
echo "📦 GGUF models:"
if [ -d "$HOME/local-llm-models/gguf" ]; then
    ls -lh "$HOME/local-llm-models/gguf"/*.gguf 2>/dev/null | sed 's/^/  /' || echo "  No GGUF models found"
else
    echo "  No GGUF directory found"
fi
echo ""
echo "💾 Disk usage:"
du -sh "$HOME/local-llm-models" 2>/dev/null || echo "  No models yet"
EOF
    
    chmod +x "$BIN_DIR/run-gguf" "$BIN_DIR/local-models-info"
    print_success "Runner scripts updated"
}

# ------------------------------------------------------------
#  Create aliases
# ------------------------------------------------------------
create_aliases() {
    print_step "Setting up permanent aliases..."
    
    if [ "$ALIASES_EXIST" = true ]; then
        echo -e "${YELLOW}Aliases already exist. Overwrite? (y/n)${NC}"
        read -r overwrite_aliases
        if [[ ! "$overwrite_aliases" =~ ^[Yy]$ ]]; then
            print_info "Keeping existing aliases"
            return
        fi
    fi
    
    cat > "$HOME/.local_llm_aliases" << 'EOF'
#!/bin/bash
# ==================== LOCAL LLM ALIASES ====================

# Colors
LRED='\033[1;31m'; LGREEN='\033[1;32m'; LYELLOW='\033[1;33m'
LBLUE='\033[1;34m'; LPURPLE='\033[1;35m'; LCYAN='\033[1;36m'; NC='\033[0m'

# Ollama commands
alias ollama-list='ollama list'
alias ollama-ps='ollama ps'
alias ollama-pull='ollama pull'
alias ollama-run='ollama run'
alias ollama-stop='ollama stop'
alias ollama-stop-all='ollama stop -a'

# Quick model shortcuts
alias run-llama='ollama run llama3.2'
alias run-mistral='ollama run mistral'
alias run-codellama='ollama run codellama'
alias run-phi='ollama run phi3'

# GGUF commands
alias gguf-list='ls -lh $HOME/local-llm-models/gguf/*.gguf 2>/dev/null'
alias gguf-run='$HOME/.local/bin/run-gguf'

# Model management
alias models-cd='cd $HOME/local-llm-models'
alias models-size='du -sh $HOME/local-llm-models/* 2>/dev/null'
alias models-info='$HOME/.local/bin/local-models-info'

# System status
alias llm-status='echo -e "${LBLUE}=== LOCAL LLM STATUS ===${NC}" && echo "" && systemctl is-active ollama >/dev/null 2>&1 && echo -e "${LCYAN}Ollama:${NC} Running" || echo -e "${LRED}Ollama:${NC} Not running" && ollama ps 2>/dev/null && echo "" && models-info'
alias llm-logs='journalctl -u ollama -f -n 30'
alias llm-restart='sudo systemctl restart ollama'

# Quick ask functions
ask() { ollama run llama3.2 "$*"; }
ask-fast() { ollama run phi3 "$*"; }
ask-code() { ollama run codellama "$*"; }

# Help function
llm-help() {
    echo -e "${LPURPLE}╔════════════════════════════════════════╗${NC}"
    echo -e "${LPURPLE}║        LOCAL LLM COMMANDS             ║${NC}"
    echo -e "${LPURPLE}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${LBLUE}📝 QUERY:${NC}"
    echo "  ask 'question'        - Ask Llama 3.2"
    echo "  ask-fast 'question'   - Ask Phi3 (faster)"
    echo "  ask-code 'code'       - Ask CodeLlama"
    echo ""
    echo -e "${LBLUE}🦙 OLLAMA:${NC}"
    echo "  ollama-list           - List models"
    echo "  ollama-ps             - Show running"
    echo "  ollama-pull <model>   - Download model"
    echo "  ollama-run <model>    - Run model"
    echo ""
    echo -e "${LBLUE}📦 GGUF:${NC}"
    echo "  gguf-list             - List GGUF files"
    echo "  gguf-run <file>       - Run GGUF model"
    echo ""
    echo -e "${LBLUE}📊 INFO:${NC}"
    echo "  models-info           - Show all models"
    echo "  llm-status            - System status"
    echo "  models-cd             - Go to models dir"
    echo ""
}

# Welcome message (only once per session)
if [[ -z "$LOCAL_LLM_WELCOME" ]]; then
    export LOCAL_LLM_WELCOME=1
    echo ""
    echo -e "${LGREEN}════════════════════════════════════════════${NC}"
    echo -e "${WHITE}     LOCAL LLM ENVIRONMENT READY           ${NC}"
    echo -e "${LGREEN}════════════════════════════════════════════${NC}"
    echo -e "${LCYAN}Type 'llm-help' for all commands${NC}"
    echo -e "${LCYAN}All models run 100% locally${NC}"
    echo ""
fi
EOF
    
    if ! grep -q "source ~/.local_llm_aliases" "$HOME/.bashrc" 2>/dev/null; then
        echo "" >> "$HOME/.bashrc"
        echo "# Load local LLM aliases" >> "$HOME/.bashrc"
        echo "[ -f ~/.local_llm_aliases ] && source ~/.local_llm_aliases" >> "$HOME/.bashrc"
    fi
    
    if [ -f "$HOME/.zshrc" ] && ! grep -q "source ~/.local_llm_aliases" "$HOME/.zshrc" 2>/dev/null; then
        echo "" >> "$HOME/.zshrc"
        echo "# Load local LLM aliases" >> "$HOME/.zshrc"
        echo "[ -f ~/.local_llm_aliases ] && source ~/.local_llm_aliases" >> "$HOME/.zshrc"
    fi
    
    print_success "Aliases configured"
}

# ------------------------------------------------------------
#  Download optional starter models
# ------------------------------------------------------------
download_models() {
    print_step "Would you like to download some tiny starter models? (y/n)"
    read -r download_choice
    
    if [[ "$download_choice" =~ ^[Yy]$ ]]; then
        mkdir -p "$MODELS_DIR/gguf"
        cd "$MODELS_DIR/gguf"
        
        echo -e "${CYAN}Downloading TinyLlama (1.1B) - runs anywhere...${NC}"
        if [ ! -f "tinyllama-1.1b.Q4_K_M.gguf" ]; then
            wget -O tinyllama-1.1b.Q4_K_M.gguf https://huggingface.co/TheBloke/TinyLlama-1.1B-GGUF/resolve/main/tinyllama-1.1b.Q4_K_M.gguf
            print_success "TinyLlama downloaded"
        else
            print_info "TinyLlama already exists"
        fi
        
        echo -e "${CYAN}Downloading Phi-2 (2.7B) - smart small model...${NC}"
        if [ ! -f "phi-2.Q4_K_M.gguf" ]; then
            wget -O phi-2.Q4_K_M.gguf https://huggingface.co/TheBloke/phi-2-GGUF/resolve/main/phi-2.Q4_K_M.gguf
            print_success "Phi-2 downloaded"
        else
            print_info "Phi-2 already exists"
        fi
        
        cd ~
    fi
}

# ------------------------------------------------------------
#  Summary
# ------------------------------------------------------------
show_summary() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}              SETUP COMPLETE - SUMMARY                 ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo -e "${CYAN}📦 Components:${NC}"
    echo -n "   Ollama: "
    if command -v ollama &> /dev/null; then
        echo -e "${GREEN}Installed${NC} ($(ollama --version 2>/dev/null | head -n1))"
        if systemctl is-active --quiet ollama 2>/dev/null; then
            echo -e "   ${GREEN}✓ Service running${NC}"
        else
            echo -e "   ${RED}✗ Service not running${NC}"
        fi
    else
        echo -e "${RED}Not installed${NC}"
    fi
    
    echo -n "   llama.cpp: "
    if [ -f "$BIN_DIR/llama-run" ]; then
        echo -e "${GREEN}Installed${NC}"
    else
        echo -e "${RED}Not installed${NC}"
    fi
    
    echo -n "   Aliases: "
    if [ -f "$HOME/.local_llm_aliases" ]; then
        echo -e "${GREEN}Configured${NC}"
    else
        echo -e "${RED}Not configured${NC}"
    fi
    
    echo ""
    echo -e "${CYAN}📁 Directories:${NC}"
    echo "   Models: $MODELS_DIR"
    echo "   Bin:    $BIN_DIR"
    echo "   Log:    $LOG_FILE"
    
    echo ""
    echo -e "${YELLOW}🔄 To start using:${NC}"
    echo "   • Open a NEW terminal"
    echo "   • Or run: source ~/.bashrc"
    echo "   • Then type: llm-help"
    echo ""
}

# ------------------------------------------------------------
#  Main
# ------------------------------------------------------------
main() {
    check_existing
    create_dirs
    install_ollama
    install_llamacpp
    create_runners
    create_aliases
    download_models
    show_summary
}

main