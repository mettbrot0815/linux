#!/bin/bash

echo "Starting system reset script for Parrot OS..."

# Update package lists
sudo apt update

# Remove all user-installed packages
echo "Removing user-installed packages..."
comm -23 <(apt-mark showmanual | sort) <(gzip -dc /var/log/installer/initial-status.gz | sed -n 's/^Package: //p' | sort) | xargs sudo apt-get -y remove --purge

# Remove orphaned packages
echo "Removing orphaned packages..."
sudo apt-get -y autoremove

# Clean up the package cache
echo "Cleaning up the package cache..."
sudo apt-get -y clean

# Reset configuration files
echo "Resetting configuration files..."
sudo dpkg-reconfigure -a

# Remove user data
echo "Removing user data..."
sudo rm -rf /home/$USER/*
sudo rm -rf /home/$USER/.*

# Reset system settings (optional, be careful with this)
# You can uncomment these lines if you want to reset some system settings
# sudo cp /etc/skel/.bashrc /home/$USER/.bashrc
# sudo cp /etc/skel/.profile /home/$USER/.profile

# Reset the hostname
echo "Resetting the hostname..."
sudo hostnamectl set-hostname parrot

echo "System reset script completed. Please reboot your system."

