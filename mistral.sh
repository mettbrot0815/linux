#!/usr/bin/env bash

# Function to detect CUDA installation
detect_cuda() {
    # Probe A: Check for nvcc in PATH
    if command -v nvcc &> /dev/null; then
        echo "CUDA detected via nvcc in PATH."
        return 0
    fi

    # Probe B: Check for libcudart.so.12
    if [ -f "/usr/lib/x86_64-linux-gnu/libcudart.so.12" ]; then
        echo "CUDA detected via libcudart.so.12."
        return 0
    fi

    # Probe C: Check dpkg for CUDA packages
    if dpkg -l | grep -q 'cuda-toolkit'; then
        echo "CUDA detected via dpkg."
        return 0
    fi

    return 1
}

# Function to download files with curl and fallback to wget
download_file() {
    local url=$1
    local output=$2

    # Try curl first
    if curl --fail -L -C - -o "$output" "$url"; then
        return 0
    fi

    # Fallback to wget
    if wget -O "$output" "$url"; then
        return 0
    fi

    echo "Download failed. You can resume the download using the following command:"
    echo "wget -c -O $output $url"
    return 1
}

# Example usage of the download function
# download_file "https://example.com/model.gguf" "/path/to/output.gguf"

# Update Qwen3 model URL to the stable repository
QWEN3_MODEL_URL="https://huggingface.co/bartowski/Qwen3-8B-GGUF/resolve/main/your-model-file.guf"

# Example of how to use the download_file function
# download_file $QWEN3_MODEL_URL "/path/to/output.gguf"
