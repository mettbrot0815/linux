#!/bin/bash

# Update package lists and install packages
echo "Updating package lists and installing packages..."
sudo apt update -y && sudo apt install -y docker.io golang-go python3-full python3-venv nala nload tor torbrowser-launcher nyx

# Verify installation
echo "Verifying installation of packages..."
packages=("docker.io" "golang-go" "python3-full" "python3-venv" "nala" "nload" "tor" "torbrowser-launcher" "nyx")
for package in "${packages[@]}"
do
    if dpkg -l | grep -q "$package"; then
        echo "$package successfully installed."
    else
        echo "$package installation failed."
    fi
done
