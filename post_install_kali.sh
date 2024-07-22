#!/bin/bash

# Update package list and upgrade installed packages
echo "Updating package list and upgrading installed packages..."
sudo apt update -y && sudo apt upgrade -y

# Install additional tools
echo "Installing additional tools..."
sudo apt install -y \
    burpsuite \
    zaproxy \
    wfuzz \
    wireshark \
    nmap \
    aircrack-ng \
    metasploit-framework \
    sqlmap \
    hashcat \
    john \
    gdb \
    ghidra \
    volatility-tools \
    sleuthkit \
    git \
    vim \
    htop

# Set up ZSH as default shell
echo "Setting up ZSH as default shell..."
sudo chsh -s /bin/zsh $(whoami)

# Configure sources.list for rolling updates
echo "Configuring sources.list for rolling updates..."
echo "deb http://http.kali.org/kali kali-rolling main non-free contrib" | sudo tee /etc/apt/sources.list
echo "deb-src http://http.kali.org/kali kali-rolling main non-free contrib" | sudo tee -a /etc/apt/sources.list

# Update package list again to include Kali's rolling repositories
echo "Updating package list again..."
sudo apt update -y

# Set up a basic Kali user for daily use (optional)
# echo "Setting up a basic Kali user for daily use..."
# echo "Please enter the desired username:"
# read USERNAME
# sudo useradd -m -s /bin/bash $USERNAME
# echo "Please enter the password for $USERNAME:"
# sudo passwd $USERNAME
# echo "User '$USERNAME' created with home directory '/home/$USERNAME'."

echo "Post-installation script completed. Enjoy your Kali Linux experience!"
