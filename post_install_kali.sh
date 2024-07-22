#!/bin/bash

# Update package list and upgrade installed packages
echo "Updating package list and upgrading installed packages..."
sudo apt update -y
sudo apt upgrade -y

# Install additional tools
echo "Installing additional tools..."
sudo apt install -y \
    # Web application analysis tools
    burp-suite \
    zap2.4 \
    wfuzz \
    # Network analysis tools
    wireshark \
    nmap \
    aircrack-ng \
    # Exploitation tools
    metasploit-framework \
    sqlmap \
    # Password cracking tools
    hashcat \
    john \
    # Reverse engineering tools
    gdb \
    ghidra \
    # Forensics tools
    volatility \
    SleuthKit \
    # Other useful tools
    git \
    vim \
    htop \
    # Set up Kali's repositories for rolling updates
    kali-rolling

# Configure sources.list for rolling updates
echo "Configuring sources.list for rolling updates..."
echo "deb http://http.kali.org/kali rolling main non-free contrib" | sudo tee -a /etc/apt/sources.list
echo "deb-src http://http.kali.org/kali rolling main non-free contrib" | sudo tee -a /etc/apt/sources.list

# Update package list again to include Kali's rolling repositories
echo "Updating package list again..."
sudo apt update -y

# Set up a basic Kali user for daily use (optional)
echo "Setting up a basic Kali user for daily use..."
echo "Please enter the desired username:"
read USERNAME
sudo useradd -m -s /bin/bash $USERNAME
echo "Please enter the password for $USERNAME:"
echo "$USERNAME:$USERNAME" | sudo chpasswd
echo "User '$USERNAME' created with home directory '/home/$USERNAME'."

echo "Post-installation script completed. Enjoy your Kali Linux experience!"