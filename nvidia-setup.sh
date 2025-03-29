#!/usr/bin/env bash
#
# nvidia-setup.sh
# Installs/updates NVIDIA drivers and Docker with NVIDIA support, optimized for Plex and FFmpeg
# Written for Ubuntu 22.04 (Jammy)

set -eo pipefail
trap 'echo -e "\n\033[1;31m[ERROR] Script failed at line $LINENO\033[0m"; exit 1' ERR

# Configuration variables
NVIDIA_DRIVER_VERSION="550" # Latest stable driver as of March 2025
CUDA_VERSION="12.4.0"
UBUNTU_VERSION="22.04"
DOCKER_COMPOSE_VERSION="v2.25.0"
ALLOW_UNSUPPORTED_OS=0

###############################################
# Enhanced Logging + Interactive Functions
###############################################
log_info()  { echo -e "\033[1;32m[INFO]  $*\033[0m"; }
log_warn()  { echo -e "\033[1;33m[WARN]  $*\033[0m"; }
log_error() { echo -e "\033[1;31m[ERR]   $*\033[0m"; }
log_prompt() { echo -e "\033[1;36m[INPUT] $*\033[0m"; }
log_step() { echo -e "\n\033[1;34m[STEP]  $*\033[0m"; }

# Progress indicator
show_progress() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    local i=0
    
    while ps -p $pid &>/dev/null; do
        local temp=${spinstr#?}
        printf "\r\033[1;36m[%c] Working...\033[0m" "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        ((i=i+1))
    done
    printf "\r\033[K"
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    while true; do
        log_prompt "$prompt [Y/n]: "
        read -r response
        response=${response:-$default}
        case "$response" in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) log_error "Please answer yes or no.";;
        esac
    done
}

# Execute command with progress spinner
run_with_progress() {
    local cmd="$*"
    log_info "Running: $cmd"
    eval "$cmd" &>/dev/null & 
    show_progress $!
    wait $! || { log_error "Command failed: $cmd"; return 1; }
    return 0
}

###############################################
# Repository and Package Management
###############################################
cleanup_nvidia_repos() {
    log_step "Cleaning up NVIDIA repository files..."
    
    # Use arrays for cleaner management
    local repo_files=(
        "/etc/apt/sources.list.d/nvidia-docker.list"
        "/etc/apt/sources.list.d/nvidia-container-toolkit.list" 
        "/etc/apt/sources.list.d/nvidia*.list"
    )
    
    local keyring_files=(
        "/etc/apt/keyrings/nvidia-docker.gpg"
        "/etc/apt/keyrings/nvidia-*.gpg"
        "/usr/share/keyrings/nvidia-docker.gpg"
        "/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
    )
    
    # Remove repo files
    for file in "${repo_files[@]}"; do
        rm -f $file
    done
    
    # Remove keyring files
    for file in "${keyring_files[@]}"; do
        rm -f $file
    done

    # Clean up driver if version mismatch detected
    if command -v nvidia-smi &>/dev/null && nvidia-smi 2>&1 | grep -q "Driver/library version mismatch"; then
        log_warn "Detected NVIDIA driver version mismatch. Cleaning up..."
        run_with_progress "apt-get remove --purge -y '^nvidia-.*'"
        run_with_progress "apt-get autoremove --purge -y"
        run_with_progress "update-initramfs -u"
    fi
}

# Optimized apt operations with caching
apt_update_cache=0
apt_update() {
    if [[ $apt_update_cache -eq 0 ]]; then
        run_with_progress "apt-get update"
        apt_update_cache=1
    fi
}

apt_install() {
    apt_update
    run_with_progress "DEBIAN_FRONTEND=noninteractive apt-get install -y $*"
}

###############################################
# Docker Status Check Functions
###############################################
check_docker_installation() {
    if command -v docker >/dev/null 2>&1; then
        log_info "Docker is already installed."
        docker_version=$(docker --version)
        log_info "Current version: $docker_version"
        return 0
    fi
    return 1
}

check_nvidia_docker() {
    if dpkg -l | grep -q nvidia-docker2; then
        log_info "NVIDIA Docker support is already installed."
        current_version=$(dpkg -l | grep nvidia-docker2 | awk '{print $3}')
        log_info "Current NVIDIA Docker version: $current_version"
        return 0
    fi
    return 1
}

check_docker_nvidia_runtime() {
    if docker info 2>/dev/null | grep -q "Runtimes:.*nvidia"; then
        log_info "NVIDIA runtime is already configured in Docker."
        return 0
    fi
    return 1
}

###############################################
# System Checks
###############################################
run_preliminary_checks() {
    log_step "Running preliminary system checks..."

    # Check root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)."
        exit 1
    fi

    # Check for NVIDIA GPU before doing anything else
    if ! lspci | grep -i nvidia > /dev/null; then
        log_error "No NVIDIA GPU detected! This script requires an NVIDIA GPU."
        exit 1
    fi

    # Offer cleanup option
    if prompt_yes_no "Would you like to clean up existing NVIDIA repositories and fix any driver mismatches?"; then
        cleanup_nvidia_repos
    fi

    # Check Ubuntu version
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$NAME" != "Ubuntu" || "$VERSION_ID" != "$UBUNTU_VERSION" ]]; then
            if [[ $ALLOW_UNSUPPORTED_OS -eq 0 ]] && ! prompt_yes_no "This script is designed for Ubuntu $UBUNTU_VERSION, but detected: $PRETTY_NAME. Continue anyway?"; then
                exit 1
            fi
        fi
    fi

    # Check for required packages - minimal set
    log_info "Installing required dependencies..."
    apt_install "curl gnupg lsb-release ca-certificates wget git"

    # Check internet connectivity
    if ! ping -c 1 8.8.8.8 &>/dev/null; then
        log_error "No internet connectivity detected!"
        if ! prompt_yes_no "Continue without internet?"; then
            exit 1
        fi
    fi
}

###############################################
# NVIDIA Driver Management
###############################################
handle_nvidia_driver() {
    log_step "Setting up NVIDIA drivers..."

    # Check for driver version mismatch
    if command -v nvidia-smi &>/dev/null && nvidia-smi 2>&1 | grep -q "Driver/library version mismatch"; then
        log_error "Driver version mismatch detected."
        if prompt_yes_no "Would you like to reinstall the NVIDIA driver to fix this?"; then
            # Remove existing drivers
            run_with_progress "apt-get remove --purge -y '^nvidia-.*'"
            run_with_progress "apt-get autoremove --purge -y"
            run_with_progress "update-initramfs -u"
        else
            log_error "Driver mismatch must be fixed to continue."
            exit 1
        fi
    fi

    # Check if drivers are already installed and working
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        log_info "Current NVIDIA installation:"
        nvidia-smi
        if ! prompt_yes_no "NVIDIA driver is already installed. Would you like to reinstall/update it?"; then
            return 0
        fi
    fi

    # Install driver dependencies
    log_info "Installing driver prerequisites..."
    apt_install "build-essential dkms linux-headers-$(uname -r) ubuntu-drivers-common pkg-config libglvnd-dev"

    # Detect recommended driver
    log_info "Detecting NVIDIA hardware..."
    ubuntu-drivers devices | grep -i nvidia
    
    # Choose installation method
    if prompt_yes_no "Install recommended NVIDIA driver automatically?"; then
        if ! run_with_progress "ubuntu-drivers autoinstall"; then
            log_warn "Driver autoinstall failed, attempting manual installation..."
            if ! apt_install "nvidia-driver-$NVIDIA_DRIVER_VERSION"; then
                log_error "Failed to install NVIDIA driver"
                return 1
            fi
        fi
    else
        # Show available drivers
        log_info "Available driver versions:"
        apt-cache search nvidia-driver- | grep "^nvidia-driver-[0-9]" | sort -V
        
        # Get user input with default
        log_prompt "Enter the desired driver version (default: $NVIDIA_DRIVER_VERSION): "
        read -r driver_version
        driver_version=${driver_version:-$NVIDIA_DRIVER_VERSION}
        
        if [[ -n "$driver_version" ]]; then
            if ! apt_install "nvidia-driver-$driver_version"; then
                log_error "Failed to install nvidia-driver-$driver_version"
                return 1
            fi
        else
            log_error "No driver version specified!"
            return 1
        fi
    fi

    # Load the module if possible
    modprobe nvidia &>/dev/null || log_warn "Could not load nvidia module (normal before reboot)"

    # Check if drivers are working
    if ! nvidia-smi &>/dev/null; then
        log_warn "nvidia-smi not working yet - you may need to reboot"
    else
        log_info "NVIDIA drivers successfully installed!"
    fi
}

###############################################
# FFmpeg and Plex Compatibility Checks
###############################################
check_media_compatibility() {
    log_step "Checking GPU capabilities for media processing..."

    if ! nvidia-smi --query-gpu=gpu_name --format=csv,noheader > /dev/null 2>&1; then
        log_warn "Cannot check GPU model - driver might not be loaded yet"
        return
    fi

    GPU_MODEL=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader 2>/dev/null)
    log_info "Detected GPU: $GPU_MODEL"

    # Create a more comprehensive compatibility profile
    if command -v nvidia-smi > /dev/null; then
        # Check NVENC/NVDEC support
        NVENC_CHECK=$(nvidia-smi -q | grep -A 4 "Encoder" || echo "")
        NVDEC_CHECK=$(nvidia-smi -q | grep -A 4 "Decoder" || echo "")
        
        # Check GPU architecture
        CUDA_CAPABILITY=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null)
        
        log_info "GPU Architecture: Compute $CUDA_CAPABILITY"
        
        if [[ -n "$NVENC_CHECK" ]]; then
            log_info "✓ NVENC (GPU encoding) is supported"
            log_info "  → Compatible with FFmpeg GPU acceleration"
            log_info "  → Compatible with Plex GPU-accelerated encoding"
            
            # Show actual encoding capabilities
            echo "$NVENC_CHECK" | grep -v "Encoder"
        else
            log_warn "✗ NVENC not detected - GPU encoding may not be available"
        fi

        if [[ -n "$NVDEC_CHECK" ]]; then
            log_info "✓ NVDEC (GPU decoding) is supported"
            log_info "  → Compatible with FFmpeg GPU acceleration"
            log_info "  → Compatible with Plex GPU-accelerated decoding"
            
            # Show actual decoding capabilities
            echo "$NVDEC_CHECK" | grep -v "Decoder"
        else
            log_warn "✗ NVDEC not detected - GPU decoding may not be available"
        fi
    fi

    # Improved GPU compatibility check
    if [[ -n "$GPU_MODEL" ]]; then
        case "$GPU_MODEL" in
            *"RTX 40"*|*"RTX 50"*)
                log_info "✓ Modern GPU detected - excellent performance expected"
                log_info "  → Full support for AV1, H.265/HEVC, H.264/AVC"
                ;;
            *"RTX 30"*)
                log_info "✓ Very good GPU model - well-supported"
                log_info "  → Good support for H.265/HEVC, H.264/AVC"
                ;;
            *"RTX 20"*|*"GTX 16"*)
                log_info "✓ Good GPU model - well-supported"
                log_info "  → Supports H.265/HEVC, H.264/AVC"
                ;;
            *"GTX 10"*)
                log_info "✓ Supported GPU model - good for most tasks"
                log_info "  → Good support for H.264/AVC, limited H.265/HEVC"
                ;;
            *"GTX 9"*|*"GTX 7"*|*"GTX 8"*)
                log_warn "! Older GPU model - limited capabilities"
                log_info "  → Basic H.264/AVC support only"
                ;;
            *"Quadro"*)
                log_info "✓ Quadro GPU detected - should work with Plex"
                ;;
            *)
                log_warn "! Unknown GPU model - check Plex compatibility manually"
                ;;
        esac
    fi

    # Check Docker GPU access
    if command -v docker &>/dev/null; then
        log_info "Testing GPU access in Docker..."
        if docker run --rm --gpus all nvidia/cuda:$CUDA_VERSION-base-ubuntu$UBUNTU_VERSION nvidia-smi &>/dev/null; then
            log_info "✓ GPU is accessible from Docker containers"
            
            # Test FFmpeg compatibility
            log_info "Testing FFmpeg hardware acceleration..."
            if ! docker run --rm --gpus all nvidia/cuda:$CUDA_VERSION-base-ubuntu$UBUNTU_VERSION \
                bash -c "apt-get update > /dev/null 2>&1 && \
                        apt-get install -y ffmpeg > /dev/null 2>&1 && \
                        ffmpeg -hide_banner -hwaccels | grep cuda" > /dev/null 2>&1; then
                log_warn "! FFmpeg CUDA acceleration test failed - might need configuration"
            else
                log_info "✓ FFmpeg CUDA acceleration test passed"
            fi
        else
            log_warn "Skipping FFmpeg test - Docker NVIDIA support not ready"
        fi
    fi

    # Print Plex configuration recommendations
    cat <<EOT

╔════════════════════════════════════════════════════════════════╗
║             Plex Configuration Recommendations                 ║
╚════════════════════════════════════════════════════════════════╝

▶ Plex Media Server Settings:
  - Enable 'Use hardware acceleration when available'
  - Set transcoder quality to 'Prefer higher quality encoding'
  - Adjust background transcoding x to 1-2 fewer than GPU cores

▶ For Docker:
  - Environment variables:
    NVIDIA_VISIBLE_DEVICES=all
    NVIDIA_DRIVER_CAPABILITIES=compute,video,utility

  - Docker run options:
    --runtime=nvidia
    -e NVIDIA_VISIBLE_DEVICES=all

▶ Docker-compose.yml example:
  plex:
    image: plexinc/pms-docker:latest
    runtime: nvidia
    environment:
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,video,utility
    ...
EOT
}

###############################################
# Docker Installation/Update
###############################################
fix_docker_config() {
    log_info "Checking Docker configuration..."
    if systemctl status docker 2>&1 | grep -q "Failed to start Docker Application Container Engine"; then
        log_warn "Detected broken Docker configuration. Fixing..."
        systemctl stop docker
        rm -f /etc/docker/daemon.json
        systemctl start docker
        return 0
    fi
    return 1
}

handle_docker_installation() {
    log_step "Setting up Docker with NVIDIA support..."
    
    # Check if Docker is already installed
    if ! check_docker_installation; then
        log_info "Installing Docker..."
        # Install Docker repositories using the official install script
        curl -fsSL https://get.docker.com -o get-docker.sh
        chmod +x get-docker.sh
        ./get-docker.sh
        rm get-docker.sh
        
        # Enable Docker to start on boot
        systemctl enable docker
    else
        # Fix Docker configuration if broken
        fix_docker_config
    fi
    
    # Install/Update NVIDIA Container Toolkit
    local nvidia_runtime_needs_install=false
    if ! check_nvidia_docker || ! check_docker_nvidia_runtime; then
        nvidia_runtime_needs_install=true
    fi
    
    if $nvidia_runtime_needs_install || prompt_yes_no "Update NVIDIA Docker support?"; then
        log_info "Setting up NVIDIA Container Toolkit..."
        
        # Check if Docker is running before preserving networks
        local networks=""
        if systemctl is-active docker &>/dev/null; then
            networks=$(docker network ls --format '{{.Name}}' 2>/dev/null || echo "")
        fi
        
        # Install nvidia-container-toolkit using their repository
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -s -L https://nvidia.github.io/libnvidia-container/ubuntu$UBUNTU_VERSION/libnvidia-container.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
        
        apt_update
        apt_install "nvidia-container-toolkit nvidia-docker2"
        
        # Configure NVIDIA runtime
        nvidia-ctk runtime configure --runtime=docker --set-as-default
        
        # Install docker-compose
        log_info "Installing Docker Compose..."
        if [ ! -f /usr/local/bin/docker-compose ]; then
            curl -SL "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
            chmod +x /usr/local/bin/docker-compose
        fi
    fi
}

###############################################
# NVIDIA NVENC & NvFBC Patching
###############################################
apply_nvidia_patches() {
    log_step "Applying NVIDIA NVENC & NvFBC unlimited sessions patch..."
    
    if prompt_yes_no "Would you like to patch NVIDIA drivers to remove NVENC session limit?"; then
        # Create temporary directory
        local patch_dir=$(mktemp -d)
        cd "$patch_dir"
        
        # Download the patch
        log_info "Downloading NVIDIA patcher..."
        run_with_progress "git clone https://github.com/keylase/nvidia-patch.git ."
        
        # Apply NVENC patch
        log_info "Applying NVENC session limit patch..."
        bash ./patch.sh
        
        # Apply NvFBC patch if needed
        if prompt_yes_no "Would you also like to patch for NvFBC support (useful for OBS and screen capture)?"; then
            log_info "Applying NvFBC patch..."
            bash ./patch-fbc.sh
        fi
        
        # Cleanup
        cd - > /dev/null
        rm -rf "$patch_dir"
        
        log_info "✓ NVIDIA driver successfully patched!"
        log_info "  → NVENC session limit removed"
        log_info "  → You can now run unlimited concurrent encoding sessions"
    fi
}

###############################################
# Docker Configuration for Media
###############################################
configure_docker_for_media() {
    log_step "Configuring Docker for media processing..."
    
    if prompt_yes_no "Configure Docker with optimized settings for NVIDIA media processing?"; then
        # Create an optimized daemon.json
        mkdir -p /etc/docker
        
        cat > /etc/docker/daemon.json <<EOF
{
    "default-runtime": "nvidia",
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    },
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "features": {
        "buildkit": true
    }
}
EOF
        
        # Restart Docker to apply changes
        systemctl restart docker
        
        # Create sample docker-compose for Plex
        mkdir -p /opt/docker-templates
        cat > /opt/docker-templates/plex-nvidia.yml <<EOF
version: '3.8'

services:
  plex:
    image: plexinc/pms-docker:latest
    container_name: plex
    restart: unless-stopped
    network_mode: host
    environment:
      - TZ=UTC
      - PLEX_CLAIM=claim-YOURCLAIMTOKEN
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,video,utility
    volumes:
      - /path/to/plex/config:/config
      - /path/to/media:/data
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu, compute, video, utility]
EOF
        
        log_info "✓ Docker configured for NVIDIA and media processing"
        log_info "⚡ Sample docker-compose template created at: /opt/docker-templates/plex-nvidia.yml"
    fi
}

###############################################
# Create Testing Scripts
###############################################
create_test_scripts() {
    log_step "Creating diagnostic and test scripts..."
    
    # Create a directory for test scripts
    mkdir -p /usr/local/bin
    
    # Test script for NVIDIA in Docker
    cat > /usr/local/bin/test-nvidia-docker.sh <<'EOF'
#!/bin/bash
echo "Testing NVIDIA GPU access inside Docker..."
docker run --rm --gpus all nvidia/cuda:latest nvidia-smi

echo -e "\nTesting FFmpeg with CUDA inside Docker..."
docker run --rm --gpus all nvidia/cuda:latest bash -c "apt-get update >/dev/null && apt-get install -y ffmpeg >/dev/null && ffmpeg -hwaccels | grep cuda"

echo -e "\nTesting NVENC encoding capabilities inside Docker..."
docker run --rm --gpus all nvidia/cuda:latest bash -c "apt-get update >/dev/null && apt-get install -y ffmpeg >/dev/null && ffmpeg -encoders | grep nvenc"
EOF

    # Test script for direct GPU transcode test
    cat > /usr/local/bin/test-transcode.sh <<'EOF'
#!/bin/bash
if [ ! -f "/tmp/test.mp4" ]; then
    echo "Downloading test video..."
    curl -L "https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4" -o /tmp/test.mp4
fi

echo "Testing CPU transcoding..."
time ffmpeg -hide_banner -loglevel error -i /tmp/test.mp4 -c:v libx264 -preset ultrafast -t 10 -f null -

echo -e "\nTesting GPU transcoding..."
time ffmpeg -hide_banner -loglevel error -i /tmp/test.mp4 -c:v h264_nvenc -preset fast -t 10 -f null -

echo -e "\nNVIDIA hardware acceleration is working if the GPU test was faster than CPU!"
EOF

    # Make scripts executable
    chmod +x /usr/local/bin/test-nvidia-docker.sh
    chmod +x /usr/local/bin/test-transcode.sh
    
    log_info "✓ Test scripts created:"
    log_info "  • /usr/local/bin/test-nvidia-docker.sh - Test GPU access in Docker"
    log_info "  • /usr/local/bin/test-transcode.sh - Test transcoding performance"
}

###############################################
# Main Installation Flow
###############################################
main() {
    log_info "╔══════════════════════════════════════════════════════════════╗"
    log_info "║  NVIDIA Driver and Media Server Setup (Optimized Edition)    ║"
    log_info "╚══════════════════════════════════════════════════════════════╝"
    log_info "This script will configure NVIDIA drivers and Docker support,"
    log_info "optimized for Plex and FFmpeg hardware acceleration."
    echo

    # Check if running in an automated environment
    if [[ -n "$AUTOMATED_INSTALL" ]]; then
        log_info "Running in automated mode with default options"
    elif ! prompt_yes_no "Ready to begin?"; then
        log_info "Setup cancelled."
        exit 0
    fi

    # Timestamp for performance tracking
    start_time=$(date +%s)
    
    # Main installation steps
    run_preliminary_checks
    handle_nvidia_driver
    apply_nvidia_patches
    handle_docker_installation
    configure_docker_for_media
    check_media_compatibility
    create_test_scripts
    
    # Calculate script execution time
    end_time=$(date +%s)
    execution_time=$((end_time - start_time))
    minutes=$((execution_time / 60))
    seconds=$((execution_time % 60))
    
    log_info "╔══════════════════════════════════════════════════════════════╗"
    log_info "║                    Setup Complete!                           ║"
    log_info "║           Completed in ${minutes}m ${seconds}s                              ║"
    log_info "╚══════════════════════════════════════════════════════════════╝"
    
    if ! nvidia-smi &>/dev/null || ! docker run --rm --gpus all nvidia/cuda:$CUDA_VERSION-base-ubuntu$UBUNTU_VERSION nvidia-smi &>/dev/null; then
        log_warn "A system reboot is required to complete the setup."
        if prompt_yes_no "Would you like to reboot now?"; then
            log_info "Rebooting system..."
            reboot
        else
            log_warn "Remember to reboot your system to complete the installation!"
        fi
    else
        log_info "Everything appears to be working correctly!"
        
        cat <<EOT

╔════════════════════════════════════════════════════════════════╗
║                     Next Steps                                 ║
╚════════════════════════════════════════════════════════════════╝

1. To verify NVIDIA GPU access in Docker:
   $ sudo /usr/local/bin/test-nvidia-docker.sh

2. To test transcoding performance:
   $ sudo /usr/local/bin/test-transcode.sh

3. To test NVENC unlimited sessions (if patched):
   $ for i in {1..10}; do ffmpeg -hwaccel cuda -i /tmp/test.mp4 -c:v h264_nvenc -b:v 5M -f null - & done

4. To configure Plex:
   - Edit the template at: /opt/docker-templates/plex-nvidia.yml
   - Run: docker-compose -f /opt/docker-templates/plex-nvidia.yml up -d

5. To monitor GPU usage:
   $ nvidia-smi dmon
EOT
    fi
}

# Run the main function
main
