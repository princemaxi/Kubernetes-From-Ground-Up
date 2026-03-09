#!/bin/bash

set -e

echo "Updating system packages..."
sudo apt update -y

echo "Installing required utilities..."
sudo apt install -y curl wget unzip jq

echo "Installing AWS CLI v2..."

if command -v aws &> /dev/null
then
    echo "AWS CLI already installed. Updating..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -o awscliv2.zip
    sudo ./aws/install --update
    rm -rf aws awscliv2.zip
else
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
    rm -rf aws awscliv2.zip
fi

echo "Installing kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

chmod +x kubectl
sudo mv kubectl /usr/local/bin/

echo "Installing CFSSL tools..."
sudo apt install -y golang-cfssl

echo "Creating kubectl alias..."
if ! grep -q "alias k=kubectl" ~/.bashrc; then
    echo "alias k=kubectl" >> ~/.bashrc
fi

echo "Reloading bash..."
source ~/.bashrc

echo "Verifying installations..."
aws --version
kubectl version --client
cfssl version

echo "Installation Complete!"
