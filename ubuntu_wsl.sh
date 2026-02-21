#!/bin/bash
# smart-local-llm.sh - Smart setup that checks what's already installed
# Run this anytime - it will only install missing components

set -e

# ==================== CONFIGURATION ====================
MODELS_DIR="$HOME/local-llm-models"
CONFIG_DIR="$HOME/.config/local-llm"
BIN_DIR="$HOME/.local/bin"
LOG_FILE="$HOME/local-llm-setup-$(date +%Y%m%d-%H%M%S).log"

# ==================== COLOR CODES ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# ==================== LOGGING ====================
exec > >(tee -a "$LOG_FILE") 2>&1

# ==================== BANNER ====================
clear
echo -e "${PURPLE}"
echo '╔═══════════════════════════════════════════════════════════════╗'
echo '║              SMART LOCAL LLM ENVIRONMENT SETUP                ║'
echo '║         Checks existing installations - No reinstall          ║'
echo '╚═══════════════════════════════════════════════════════════════╝'
echo -e "${NC}"
echo ""

# ==================== HELPER FUNCTIONS ====================
print_step() { echo -e "\n${BLUE}🔧 $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️ $1${NC}"; }
print_info() { echo -e "${CYAN}ℹ️ $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

# ==================== CHECK EXISTING INSTALLATIONS ====================
check_existing() {
    print_step "Checking existing installations..."
    
    # Check Ollama
    if command -v ollama &> /dev/null; then
        OLLAMA_EXISTS=true
        OLLAMA_VERSION=$(ollama --version 2>/dev/null | head -n1 || echo "unknown")
        print_success "Ollama already installed: $OLLAMA_VERSION"
    else
        OLLAMA_EXISTS=false
        print_info "Ollama not found"
    fi
    
    # Check llama.cpp
    if [ -f "$BIN_DIR/llama-run" ] || [ -f "$BIN_DIR/main" ]; then
        LLAMACPP_EXISTS=true
        print_success "llama.cpp already installed"
    else
        LLAMACPP_EXISTS=false
        print_info "llama.cpp not found"
    fi
    
    # Check directories
    if [ -d "$MODELS_DIR" ]; then
        MODELS_EXIST=true
        MODEL_COUNT=$(find "$MODELS_DIR" -name "*.gguf" -o -name "*.bin" 2>/dev/null | wc -l)
        print_success "Models directory exists with $MODEL_COUNT models"
    else
        MODELS_EXIST=false
        print_info "Models directory not found"
    fi
    
    # Check aliases
    if [ -f "$HOME/.local_llm_aliases" ]; then
        ALIASES_EXIST=true
        print_success "LLM aliases already configured"
    else
        ALIASES_EXIST=false
        print_info "LLM aliases not found"
    fi
    
    echo ""
}

# ==================== ASK ABOUT REINSTALL ====================
ask_reinstall() {
    local component=$1
    local current_version=$2
    
    echo -e "${YELLOW}⚠️  $component is already installed.${NC}"
    echo -e "   Current version: ${CYAN}$current_version${NC}"
    echo -e "   Do you want to:"
    echo -e "   ${GREEN}[s]${NC} Skip (keep current)"
    echo -e "   ${GREEN}[r]${NC} Reinstall"
    echo -e "   ${GREEN}[u]${NC} Update if possible"
    read -p "Choice [s/r/u]: " choice
    
    case $choice in
        r|R) return 0 ;;  # Reinstall
        u|U) return 2 ;;  # Update
        *) return 1 ;;    # Skip
    esac
}

# ==================== CREATE DIRECTORY STRUCTURE ====================
create_dirs() {
    print_step "Setting up directory structure..."
    
    local dirs_created=0
    
    [ ! -d "$MODELS_DIR" ] && mkdir -p "$MODELS_DIR"/{ollama,gguf,llamacpp,temp} && dirs_created=$((dirs_created+1))
    [ ! -d "$BIN_DIR" ] && mkdir -p "$BIN_DIR" && dirs_created=$((dirs_created+1))
    [ ! -d "$CONFIG_DIR" ] && mkdir -p "$CONFIG_DIR" && dirs_created=$((dirs_created+1))
    
    if [ $dirs_created -gt 0 ]; then
        print_success "Created $dirs_created new directories"
    else
        print_info "All directories already exist"
    fi
}

# ==================== INSTALL OLLAMA (WITH CHECKS) ====================
install_ollama() {
    print_step "Setting up Ollama..."
    
    if [ "$OLLAMA_EXISTS" = true ]; then
        ask_reinstall "Ollama" "$OLLAMA_VERSION"
        local choice=$?
        if [ $choice -eq 1 ]; then
            print_info "Skipping Ollama installation"
            return
        elif [ $choice -eq 2 ]; then
            print_step "Attempting to update Ollama..."
            curl -fsSL https://ollama.com/install.sh | sh
            print_success "Ollama updated"
        fi
    else
        print_info "Installing Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
    fi
    
    # Always ensure service is configured correctly
    if systemctl list-units --full -all | grep -Fq "ollama.service"; then
        sudo systemctl stop ollama 2>/dev/null || true
        
        # Configure for local-only use
        sudo mkdir -p /etc/ollama
        sudo tee /etc/ollama/config.json > /dev/null <<EOF
{
    "disable_telemetry": true,
    "disable_update_check": true,
    "models_dir": "$MODELS_DIR/ollama"
}
EOF
        
        # Update service
        sudo tee /etc/systemd/system/ollama.service > /dev/null <<EOF
[Unit]
Description=Ollama Service - Local Only
After=network.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=$USER
Group=$USER
Restart=always
Environment="OLLAMA_HOST=127.0.0.1"
Environment="OLLAMA_MODELS=$MODELS_DIR/ollama"
Environment="OLLAMA_KEEP_ALIVE=24h"
Environment="OLLAMA_DISABLE_TELEMETRY=1"

[Install]
WantedBy=default.target
EOF
        
        sudo systemctl daemon-reload
        sudo systemctl enable ollama
        sudo systemctl start ollama
        print_success "Ollama service configured"
    fi
}

# ==================== INSTALL LLAMA.CPP (WITH CHECKS) ====================
install_llamacpp() {
    print_step "Setting up llama.cpp..."
    
    if [ "$LLAMACPP_EXISTS" = true ]; then
        ask_reinstall "llama.cpp" "existing build"
        local choice=$?
        if [ $choice -eq 1 ]; then
            print_info "Skipping llama.cpp installation"
            return
        fi
        # If reinstall or update, continue to build
    fi
    
    print_info "Building llama.cpp from source..."
    cd /tmp
    if [ -d "llama.cpp" ]; then
        cd llama.cpp
        git pull
    else
        git clone https://github.com/ggerganov/llama.cpp.git
        cd llama.cpp
    fi
    
    make clean
    make -j$(nproc)
    
    # Install binaries
    cp main server llama-quantize "$BIN_DIR/" 2>/dev/null || true
    ln -sf "$BIN_DIR/main" "$BIN_DIR/llama-run" 2>/dev/null || true
    ln -sf "$BIN_DIR/server" "$BIN_DIR/llama-serve" 2>/dev/null || true
    
    cd ~
    print_success "llama.cpp installed/updated"
}

# ==================== CREATE/UPDATE RUNNERS ====================
create_runners() {
    print_step "Setting up model runners..."
    
    local runners_updated=0
    
    # GGUF runner
    if [ ! -f "$BIN_DIR/run-gguf" ] || [ "$(cat "$BIN_DIR/run-gguf" 2>/dev/null | wc -l)" -lt 10 ]; then
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
        chmod +x "$BIN_DIR/run-gguf"
        runners_updated=$((runners_updated+1))
    fi
    
    # Model info script
    if [ ! -f "$BIN_DIR/local-models-info" ]; then
        cat > "$BIN_DIR/local-models-info" << 'EOF'
#!/bin/bash
echo "📊 LOCAL MODELS STATUS"
echo "======================"
echo ""

echo "🦙 Ollama models:"
ollama list 2>/dev/null || echo "  No Ollama models found"
echo ""

echo "📦 GGUF models:"
ls -lh "$HOME/local-llm-models/gguf"/*.gguf 2>/dev/null | sed 's/^/  /' || echo "  No GGUF models found"
echo ""

echo "💾 Disk usage:"
du -sh "$HOME/local-llm-models" 2>/dev/null || echo "  No models yet"
EOF
        chmod +x "$BIN_DIR/local-models-info"
        runners_updated=$((runners_updated+1))
    fi
    
    if [ $runners_updated -gt 0 ]; then
        print_success "Updated $runners_updated runner scripts"
    else
        print_info "Runner scripts already exist"
    fi
}

# ==================== CREATE/UPDATE ALIASES ====================
create_aliases() {
    print_step "Setting up permanent aliases..."
    
    if [ "$ALIASES_EXIST" = true ]; then
        ask_reinstall "LLM aliases" "existing"
        local choice=$?
        if [ $choice -eq 1 ]; then
            print_info "Keeping existing aliases"
            return
        fi
    fi
    
    cat > "$HOME/.local_llm_aliases" << 'EOF'
#!/bin/bash
# ==================== LOCAL LLM ALIASES ====================

# Colors
LRED='\033[1;31m'
LGREEN='\033[1;32m'
LYELLOW='\033[1;33m'
LBLUE='\033[1;34m'
LPURPLE='\033[1;35m'
LCYAN='\033[1;36m'
NC='\033[0m'

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

# Welcome message (only once)
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
    
    # Add to bashrc if not already there
    if ! grep -q "local_llm_aliases" "$HOME/.bashrc"; then
        echo "" >> "$HOME/.bashrc"
        echo "# Load local LLM aliases" >> "$HOME/.bashrc"
        echo "[ -f ~/.local_llm_aliases ] && source ~/.local_llm_aliases" >> "$HOME/.bashrc"
    fi
    
    if [ -f "$HOME/.zshrc" ] && ! grep -q "local_llm_aliases" "$HOME/.zshrc"; then
        echo "" >> "$HOME/.zshrc"
        echo "# Load local LLM aliases" >> "$HOME/.zshrc"
        echo "[ -f ~/.local_llm_aliases ] && source ~/.local_llm_aliases" >> "$HOME/.zshrc"
    fi
    
    print_success "Aliases configured"
}

# ==================== DOWNLOAD OPTIONAL MODELS ====================
download_models() {
    if [ "$MODELS_EXIST" = true ] && [ "$MODEL_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}You already have $MODEL_COUNT models. Download more? (y/n)${NC}"
        read -r download_more
        if [[ ! "$download_more" =~ ^[Yy]$ ]]; then
            return
        fi
    fi
    
    print_step "Would you like to download some tiny starter models? (y/n)"
    read -r download_choice
    
    if [[ "$download_choice" =~ ^[Yy]$ ]]; then
        print_info "Downloading TinyLlama (1.1B) - runs anywhere..."
        cd "$MODELS_DIR/gguf"
        wget -O tinyllama-1.1b.Q4_K_M.gguf https://huggingface.co/TheBloke/TinyLlama-1.1B-GGUF/resolve/main/tinyllama-1.1b.Q4_K_M.gguf
        print_success "TinyLlama downloaded"
    fi
}

# ==================== SUMMARY ====================
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
    echo "   Config: $CONFIG_DIR"
    echo "   Log:    $LOG_FILE"
    
    echo ""
    echo -e "${YELLOW}🔄 To start using:${NC}"
    echo "   • Open a NEW terminal"
    echo "   • Or run: source ~/.bashrc"
    echo "   • Then type: llm-help"
    echo ""
}

# ==================== MAIN ====================
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

# Run it
main