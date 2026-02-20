# ============================================================================
# STEP 5: Security & Pentesting Tools Selection (NEW)
# ============================================================================
print_section "STEP 5: Security & Pentesting Tools Selection"

sec_options=(
    "PentAGI - Autonomous AI penetration testing (Docker + complex stack)"
    "PentestAgent - AI agent framework for black-box testing"
    "HackerAI - Web-based AI penetration testing assistant"
    "HexStrike AI - MCP server with 150+ security tools"
)

echo "Select security/pentesting tools to install (space-separated numbers):"
for i in "${!sec_options[@]}"; do
    echo "  $((i+1)). ${sec_options[$i]}"
done
echo ""
read -p "Enter numbers (e.g., 1 2 3): " -a sec_choices

for choice in "${sec_choices[@]}"; do
    case $choice in
        1)
            print_info "Installing PentAGI..."
            # Check Docker
            if ! command -v docker &> /dev/null; then
                print_warning "Docker not found. Please install Docker first (option in Dev Tools)."
            else
                # Clone repo
                git clone https://github.com/vxcontrol/pentagi.git ~/pentagi
                cd ~/pentagi
                # Copy env example
                cp .env.example .env
                print_info "Please edit ~/pentagi/.env to add your API keys (OpenAI, Anthropic, etc.)"
                # Start with docker-compose
                docker-compose up -d
                cd ~
                print_status "PentAGI installed! Access web UI at http://localhost:8080"
                print_info "To stop: cd ~/pentagi && docker-compose down"
            fi
            ;;
        2)
            print_info "Installing PentestAgent..."
            # Check Python 3.10+
            python_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
            if [[ $(echo "$python_version < 3.10" | bc) -eq 1 ]]; then
                print_error "PentestAgent requires Python 3.10+. Current: $python_version"
            else
                git clone https://github.com/GH05TCREW/pentestagent.git ~/pentestagent
                cd ~/pentestagent
                # Run their setup script
                if [[ -f "scripts/setup.sh" ]]; then
                    chmod +x scripts/setup.sh
                    ./scripts/setup.sh
                else
                    # Manual setup
                    python3 -m venv venv
                    source venv/bin/activate
                    pip install -e ".[all]"
                    playwright install chromium
                    deactivate
                fi
                # Create .env from example
                cp .env.example .env
                print_info "Please edit ~/pentestagent/.env to add your API keys"
                # Add alias
                echo "alias pentestagent='cd ~/pentestagent && source venv/bin/activate && pentestagent'" >> ~/.bashrc
                cd ~
                print_status "PentestAgent installed! Run with: pentestagent"
            fi
            ;;
        3)
            print_info "Installing HackerAI..."
            # Check Node.js and pnpm
            if ! command -v node &> /dev/null; then
                print_warning "Node.js not found. Please install Node.js first (option in Dev Tools)."
            else
                # Install pnpm if not present
                if ! command -v pnpm &> /dev/null; then
                    print_info "Installing pnpm..."
                    npm install -g pnpm
                fi
                git clone https://github.com/hackerai-tech/hackerai.git ~/hackerai
                cd ~/hackerai
                pnpm install
                pnpm run setup
                print_info "HackerAI requires multiple API keys and services."
                print_info "Please follow the setup guide at: https://github.com/hackerai-tech/hackerai"
                print_info "After configuration, run: cd ~/hackerai && pnpm run dev"
                cd ~
                print_status "HackerAI installed! See instructions above."
            fi
            ;;
        4)
            print_info "Installing HexStrike AI..."
            # Check Python
            git clone https://github.com/0x4m4/hexstrike-ai.git ~/hexstrike-ai
            cd ~/hexstrike-ai
            # Create virtual environment
            python3 -m venv hexstrike-env
            source hexstrike-env/bin/activate
            pip install -r requirements.txt
            deactivate
            # Install system security tools (list from their README)
            print_info "Installing security tools (this may take a while)..."
            sudo apt update
            sudo apt install -y nmap masscan rustscan amass subfinder nuclei fierce dnsenum \
                autorecon theharvester responder netexec enum4linux-ng gobuster feroxbuster \
                dirsearch ffuf dirb httpx katana nikto sqlmap wpscan arjun paramspider dalfox \
                wafw00f hydra john hashcat medusa patator evil-winrm gdb radare2 binwalk \
                checksec foremost steghide exiftool chromium-browser
            # Also install some Go tools
            print_info "Installing Go tools (if Go is installed)..."
            if command -v go &> /dev/null; then
                go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest
                go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest
                # Add more as needed
            else
                print_warning "Go not installed. Some tools may be missing."
            fi
            # Create start script
            cat > ~/hexstrike-ai/start.sh << 'EOF'
#!/bin/bash
cd ~/hexstrike-ai
source hexstrike-env/bin/activate
python3 hexstrike_server.py
EOF
            chmod +x ~/hexstrike-ai/start.sh
            # Add alias
            echo "alias hexstrike='~/hexstrike-ai/start.sh'" >> ~/.bashrc
            cd ~
            print_status "HexStrike AI installed! Run with: hexstrike"
            print_info "Configure AI clients as per their documentation."
            ;;
    esac
done
