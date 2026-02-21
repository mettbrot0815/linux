#!/bin/bash
# ultimate-local-llm.sh - 100% LOCAL LLM setup
# No cloud, no Docker, just pure local models

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
echo '║              PURE LOCAL LLM ENVIRONMENT SETUP                 ║'
echo '║                    No Cloud - No BS                            ║'
echo '╚═══════════════════════════════════════════════════════════════╝'
echo -e "${NC}"
echo ""

# ==================== HELPER FUNCTIONS ====================
print_step() { echo -e "\n${BLUE}🔧 $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️ $1${NC}"; }

# ==================== CREATE DIRECTORY STRUCTURE ====================
create_dirs() {
    print_step "Creating local LLM directories..."
    
    mkdir -p "$MODELS_DIR"/{ollama,llamacpp,gguf,temp}
    mkdir -p "$BIN_DIR"
    mkdir -p "$CONFIG_DIR"
    
    print_success "Directory structure created"
}

# ==================== INSTALL OLLAMA (PURE LOCAL) ====================
install_ollama() {
    print_step "Installing Ollama for local models..."
    
    # Download and install Ollama
    curl -fsSL https://ollama.com/install.sh | sh
    
    # Stop any running Ollama
    sudo systemctl stop ollama 2>/dev/null || true
    
    # Configure Ollama for PURE LOCAL use (no telemetry, no internet)
    sudo mkdir -p /etc/ollama
    
    # Create config that disables all network features
    sudo tee /etc/ollama/config.json > /dev/null <<'EOF'
{
    "disable_telemetry": true,
    "disable_update_check": true,
    "disable_metrics": true,
    "read_only": false,
    "models_dir": "'$HOME'/local-llm-models/ollama",
    "keep_alive": "24h",
    "num_parallel": 1,
    "max_loaded_models": 1
}
EOF
    
    # Modify service to be completely local
    sudo tee /etc/systemd/system/ollama.service > /dev/null <<'EOF'
[Unit]
Description=Ollama Service - Local Only
After=network.target
Before=network-online.target
Wants=network.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=%USER%
Group=%USER%
Restart=always
RestartSec=3
Environment="OLLAMA_HOST=127.0.0.1"
Environment="OLLAMA_MODELS=/home/%USER%/local-llm-models/ollama"
Environment="OLLAMA_KEEP_ALIVE=24h"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_DISABLE_TELEMETRY=1"
Environment="OLLAMA_NO_UPDATE_CHECK=1"

[Install]
WantedBy=default.target
EOF
    
    # Replace %USER% with actual username
    sudo sed -i "s/%USER%/$USER/g" /etc/systemd/system/ollama.service
    
    # Reload and start
    sudo systemctl daemon-reload
    sudo systemctl enable ollama
    sudo systemctl start ollama
    
    print_success "Ollama installed in LOCAL-ONLY mode"
}

# ==================== INSTALL LLAMA.CPP (THE REAL DEAL) ====================
install_llamacpp() {
    print_step "Installing llama.cpp for maximum local control..."
    
    # Clone and build
    cd /tmp
    git clone https://github.com/ggerganov/llama.cpp.git
    cd llama.cpp
    make clean
    make -j$(nproc)
    
    # Install to local bin
    cp main server llama-quantize llama-perplexity embedding "$BIN_DIR/"
    cp -r models "$MODELS_DIR/llamacpp-models" 2>/dev/null || true
    
    # Create symlinks
    ln -sf "$BIN_DIR/main" "$BIN_DIR/llama-run"
    ln -sf "$BIN_DIR/server" "$BIN_DIR/llama-serve"
    
    cd ~
    rm -rf /tmp/llama.cpp
    
    print_success "llama.cpp installed - FULL local control"
}

# ==================== DOWNLOAD SOME BASIC MODELS (OPTIONAL) ====================
download_basic_models() {
    print_step "Do you want to download some basic local models? (y/n)"
    read -r download_choice
    
    if [[ "$download_choice" =~ ^[Yy]$ ]]; then
        print_step "Downloading tiny local models to get started..."
        
        # Tiny models that run anywhere (no GPU needed)
        echo -e "${CYAN}📥 Downloading TinyLlama (1.1B) - runs on ANY hardware...${NC}"
        cd "$MODELS_DIR/gguf"
        wget -O tinyllama-1.1b.Q4_K_M.gguf https://huggingface.co/TheBloke/TinyLlama-1.1B-GGUF/resolve/main/tinyllama-1.1b.Q4_K_M.gguf
        
        echo -e "${CYAN}📥 Downloading Phi-2 (2.7B) - smart small model...${NC}"
        wget -O phi-2.Q4_K_M.gguf https://huggingface.co/TheBloke/phi-2-GGUF/resolve/main/phi-2.Q4_K_M.gguf
        
        # Ollama will pull models on demand when you run them
        echo -e "${YELLOW}Note: Other models will be downloaded when you first run them${NC}"
    else
        print_warning "Skipping model downloads - you can download later"
    fi
}

# ==================== CREATE LOCAL MODEL RUNNERS ====================
create_runners() {
    print_step "Creating local model runner scripts..."
    
    # Create runner for GGUF models
    cat > "$BIN_DIR/run-gguf" << 'EOF'
#!/bin/bash
# Simple GGUF model runner using llama.cpp

MODEL_DIR="$HOME/local-llm-models/gguf"
BIN_DIR="$HOME/.local/bin"

if [ $# -lt 1 ]; then
    echo "Usage: run-gguf <model-file> [prompt]"
    echo ""
    echo "Available models:"
    ls -1 "$MODEL_DIR"/*.gguf 2>/dev/null | xargs -n1 basename || echo "No models found"
    exit 1
fi

MODEL="$MODEL_DIR/$1"
if [ ! -f "$MODEL" ]; then
    echo "Model not found: $MODEL"
    exit 1
fi

PROMPT="${2:-'Hello, how are you?'}"
echo "🚀 Running $1 locally..."
echo ""

"$BIN_DIR/llama-run" -m "$MODEL" -p "$PROMPT" -n 512 -t 4
EOF
    
    # Create Ollama runner with local-only focus
    cat > "$BIN_DIR/ollama-local" << 'EOF'
#!/bin/bash
# Local-only Ollama wrapper

export OLLAMA_HOST=127.0.0.1
export OLLAMA_MODELS="$HOME/local-llm-models/ollama"

case "$1" in
    run)
        shift
        echo "🦙 Running local model: $1"
        ollama run "$@"
        ;;
    list)
        echo "📋 Local models:"
        ollama list
        ;;
    pull)
        shift
        echo "📥 Pulling model locally: $1"
        ollama pull "$@"
        ;;
    *)
        ollama "$@"
        ;;
esac
EOF
    
    # Create model info script
    cat > "$BIN_DIR/local-models-info" << 'EOF'
#!/bin/bash
# Show info about local models

echo "📊 LOCAL MODELS STATUS"
echo "======================"
echo ""

echo "🦙 Ollama models:"
if command -v ollama >/dev/null; then
    ollama list 2>/dev/null || echo "  No Ollama models found"
else
    echo "  Ollama not installed"
fi
echo ""

echo "📦 GGUF models (llama.cpp):"
GGUF_DIR="$HOME/local-llm-models/gguf"
if [ -d "$GGUF_DIR" ]; then
    find "$GGUF_DIR" -name "*.gguf" -exec basename {} \; 2>/dev/null | sed 's/^/  /' || echo "  No GGUF models found"
else
    echo "  No GGUF models found"
fi
echo ""

echo "💾 Total disk usage:"
du -sh "$HOME/local-llm-models" 2>/dev/null || echo "  No models yet"
EOF
    
    # Make all scripts executable
    chmod +x "$BIN_DIR"/*
    
    print_success "Local model runners created"
}

# ==================== CREATE PERSISTENT ALIASES ====================
create_aliases() {
    print_step "Creating permanent LOCAL aliases..."
    
    # Create aliases file
    cat > "$HOME/.local_llm_aliases" << 'EOF'
#!/bin/bash
# ==================== 100% LOCAL LLM ALIASES ====================
# These load every time you open a terminal

# Colors
LRED='\033[1;31m'
LGREEN='\033[1;32m'
LYELLOW='\033[1;33m'
LBLUE='\033[1;34m'
LPURPLE='\033[1;35m'
LCYAN='\033[1;36m'
NC='\033[0m'

# ==================== OLLAMA LOCAL COMMANDS ====================
alias ollama-local='ollama'
alias ollama-list='ollama list'
alias ollama-ps='ollama ps'
alias ollama-stop='ollama stop'
alias ollama-stop-all='ollama stop -a'
alias ollama-pull='ollama pull'
alias ollama-run='ollama run'

# Quick model shortcuts (downloads on first use)
alias run-llama='ollama run llama3.2'
alias run-mistral='ollama run mistral'
alias run-codellama='ollama run codellama'
alias run-phi='ollama run phi3'
alias run-neural='ollama run neural-chat'

# ==================== LLAMA.CPP LOCAL COMMANDS ====================
alias llamacpp='$HOME/.local/bin/llama-run'
alias llama-server='$HOME/.local/bin/llama-serve'
alias gguf-list='ls -lh $HOME/local-llm-models/gguf/*.gguf 2>/dev/null'
alias gguf-run='$HOME/.local/bin/run-gguf'

# ==================== LOCAL MODEL MANAGEMENT ====================
alias models-cd='cd $HOME/local-llm-models'
alias models-size='du -sh $HOME/local-llm-models/* 2>/dev/null'
alias models-info='$HOME/.local/bin/local-models-info'
alias models-ollama='cd $HOME/local-llm-models/ollama'
alias models-gguf='cd $HOME/local-llm-models/gguf'

# ==================== SYSTEM STATUS ====================
alias llm-status='echo -e "${LBLUE}=== LOCAL LLM STATUS ===${NC}" && echo "" && echo -e "${LCYAN}Ollama:${NC}" && systemctl is-active ollama 2>/dev/null && ollama ps 2>/dev/null && echo "" && echo -e "${LCYAN}Models:${NC}" && du -sh $HOME/local-llm-models/* 2>/dev/null'
alias llm-logs='journalctl -u ollama -f -n 50'
alias llm-restart='sudo systemctl restart ollama'

# ==================== LOCAL TEXT GENERATION ====================
ask() {
    if [ $# -eq 0 ]; then
        echo "Usage: ask <prompt>"
        return 1
    fi
    ollama run llama3.2 "$*"
}

ask-fast() {
    if [ $# -eq 0 ]; then
        echo "Usage: ask-fast <prompt>"
        return 1
    fi
    ollama run phi3 "$*"
}

ask-code() {
    if [ $# -eq 0 ]; then
        echo "Usage: ask-code <prompt>"
        return 1
    fi
    ollama run codellama "$*"
}

# ==================== LOCAL HELP ====================
llm-help() {
    echo -e "${LPURPLE}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${LPURPLE}║       100% LOCAL LLM COMMANDS                 ║${NC}"
    echo -e "${LPURPLE}╚════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${LBLUE}📝 QUERY MODELS:${NC}"
    echo -e "  ${LGREEN}ask 'your question'${NC}         - Ask Llama 3.2"
    echo -e "  ${LGREEN}ask-fast 'question'${NC}         - Ask Phi3 (faster)"
    echo -e "  ${LGREEN}ask-code 'write function'${NC}   - Ask CodeLlama"
    echo ""
    echo -e "${LBLUE}🦙 OLLAMA:${NC}"
    echo -e "  ${LGREEN}ollama-list${NC}                  - List local models"
    echo -e "  ${LGREEN}ollama-ps${NC}                    - Show running models"
    echo -e "  ${LGREEN}ollama-pull <model>${NC}          - Download model locally"
    echo -e "  ${LGREEN}ollama-run <model>${NC}           - Run a model"
    echo -e "  ${LGREEN}ollama-stop-all${NC}              - Stop all models"
    echo ""
    echo -e "${LBLUE}📦 GGUF MODELS (llama.cpp):${NC}"
    echo -e "  ${LGREEN}gguf-list${NC}                    - List GGUF files"
    echo -e "  ${LGREEN}gguf-run <file> <prompt>${NC}     - Run GGUF model"
    echo ""
    echo -e "${LBLUE}📊 MODEL MANAGEMENT:${NC}"
    echo -e "  ${LGREEN}models-info${NC}                  - Show all local models"
    echo -e "  ${LGREEN}models-size${NC}                  - Check disk usage"
    echo -e "  ${LGREEN}models-cd${NC}                    - Go to models directory"
    echo -e "  ${LGREEN}llm-status${NC}                   - Show system status"
    echo ""
    echo -e "${LBLUE}📁 MODEL LOCATIONS:${NC}"
    echo -e "  ${LYELLOW}Ollama:${NC} ~/local-llm-models/ollama/"
    echo -e "  ${LYELLOW}GGUF:${NC}   ~/local-llm-models/gguf/"
    echo ""
}

# Show welcome message on terminal open (only once)
if [[ -z "$LOCAL_LLM_WELCOME" ]]; then
    export LOCAL_LLM_WELCOME=1
    echo ""
    echo -e "${LGREEN}════════════════════════════════════════════════${NC}"
    echo -e "${LWHITE}     🌍 PURE LOCAL LLM ENVIRONMENT READY       ${NC}"
    echo -e "${LGREEN}════════════════════════════════════════════════${NC}"
    echo -e "${LCYAN}Type 'llm-help' for all local commands${NC}"
    echo -e "${LCYAN}All models run 100% locally - no internet needed${NC}"
    echo ""
fi
EOF
    
    # Add to bashrc if not already there
    if ! grep -q "local_llm_aliases" "$HOME/.bashrc"; then
        echo "" >> "$HOME/.bashrc"
        echo "# Load local LLM aliases" >> "$HOME/.bashrc"
        echo "if [ -f ~/.local_llm_aliases ]; then" >> "$HOME/.bashrc"
        echo "    source ~/.local_llm_aliases" >> "$HOME/.bashrc"
        echo "fi" >> "$HOME/.bashrc"
    fi
    
    # Also add for zsh if it exists
    if [ -f "$HOME/.zshrc" ]; then
        if ! grep -q "local_llm_aliases" "$HOME/.zshrc"; then
            echo "" >> "$HOME/.zshrc"
            echo "# Load local LLM aliases" >> "$HOME/.zshrc"
            echo "if [ -f ~/.local_llm_aliases ]; then" >> "$HOME/.zshrc"
            echo "    source ~/.local_llm_aliases" >> "$HOME/.zshrc"
            echo "fi" >> "$HOME/.zshrc"
        fi
    fi
    
    print_success "Permanent aliases created - they'll show every terminal open"
}

# ==================== FINAL MESSAGE ====================
show_final_message() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}           ✅ LOCAL LLM SETUP COMPLETE! ✅             ${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}📁 Everything is local:${NC}"
    echo -e "   Models:     $MODELS_DIR"
    echo -e "   Config:     $CONFIG_DIR"
    echo -e "   Binaries:   $BIN_DIR"
    echo -e "   Log file:   $LOG_FILE"
    echo ""
    echo -e "${YELLOW}🔄 Open a NEW terminal or run: source ~/.bashrc${NC}"
    echo ""
    echo -e "${PURPLE}📝 Quick test:${NC}"
    echo -e "   ${WHITE}1. Open new terminal${NC}"
    echo -e "   ${WHITE}2. Type 'llm-help' to see all commands${NC}"
    echo -e "   ${WHITE}3. Type 'ollama-pull tinyllama' for a tiny test model${NC}"
    echo -e "   ${WHITE}4. Type 'ask \"Hello\"' to test${NC}"
    echo ""
    echo -e "${GREEN}All models run 100% locally. No phoning home. No cloud.${NC}"
    echo ""
}

# ==================== MAIN EXECUTION ====================
main() {
    create_dirs
    install_ollama
    install_llamacpp
    create_runners
    create_aliases
    download_basic_models
    
    # Source the aliases for current session
    source "$HOME/.local_llm_aliases" 2>/dev/null || true
    
    show_final_message
}

# Run it
main