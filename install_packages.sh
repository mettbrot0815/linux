#!/bin/bash

# Function to check if a package is installed
is_package_installed() {
    dpkg -l "$1" &> /dev/null
}

# List of packages to install
PACKAGES=(
    "neofetch"
    "htop"
    "nmap"
    "wireshark"
    "gparted"
    "vlc"
    "openvpn"
    "git"
    "curl"
    "wget"
    "python3"
    "python3-pip"
    "build-essential"
    "virtualbox"
)

# Update package lists
sudo apt update

# Install packages
for package in "${PACKAGES[@]}"; do
    if is_package_installed "$package"; then
        echo "$package is already installed."
    else
        sudo apt install -y "$package"
    fi
done

# Optionally install additional packages specific to Kali Linux
# Uncomment and modify as needed
# sudo apt install -y kali-linux-full

# Display installed packages
echo "Installed packages:"
dpkg -l | grep '^ii'
