#!/usr/bin/env bash
#
# nvidia-setup.sh
# Installs/updates NVIDIA drivers and Docker with NVIDIA support, optimized for Plex and FFmpeg
# Written for Ubuntu 22.04 (Jammy)

set -eo pipefail
trap 'echo -e "\n\033[1;31m[ERROR] Script failed at line $LINENO\033[0m"; exit 1' ERR

# Configuration variables
UBUNTU_VERSION="22.04"
DOCKER_COMPOSE_VERSION="v2.25.0"
CUDA_VERSION="12.4.0"  # Default CUDA version

###############################################
# Enhanced Logging + Interactive Functions
###############################################
log_info()  { echo -e "\033[1;32m[INFO]  $*\033[0m"; }
log_warn()  { echo -e "\033[1;33m[WARN]  $*\033[0m"; }
log_error() { echo -e "\033[1;31m[ERROR] $*\033[0m"; }
log_prompt() { echo -e "\033[1;36m[INPUT] $*\033[0m"; }
log_step() { echo -e "\n\033[1;34m[STEP]  $*\033[0m"; }

# Execute command without progress spinner
run_command() {
    local cmd="$*"
    log_info "Running: $cmd"
    eval "$cmd" || { log_error "Command failed: $cmd"; return 1; }
    return 0
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

###############################################
# Package and Repository Management
###############################################
apt_update_cache=0
apt_update() {
    if [[ $apt_update_cache -eq 0 ]]; then
        run_command "apt-get update"
        apt_update_cache=1
    fi
}

apt_install() {
    apt_update
    run_command "DEBIAN_FRONTEND=noninteractive apt-get install -y $*"
}

cleanup_nvidia_repos() {
    log_step "Cleaning up NVIDIA repository files..."

    # Remove repo files
    rm -f /etc/apt/sources.list.d/nvidia-docker.list
    rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
    rm -f /etc/apt/sources.list.d/nvidia*.list

    # Remove keyring files
    rm -f /etc/apt/keyrings/nvidia-docker.gpg
    rm -f /etc/apt/keyrings/nvidia-*.gpg
    rm -f /usr/share/keyrings/nvidia-docker.gpg
    rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    # Clean up driver if version mismatch detected
    if command -v nvidia-smi &>/dev/null && nvidia-smi 2>&1 | grep -q "Driver/library version mismatch"; then
        log_warn "Detected NVIDIA driver version mismatch. Cleaning up..."
        run_command "apt-get remove --purge -y '^nvidia-.*'"
        run_command "apt-get autoremove --purge -y"
        run_command "update-initramfs -u"
    fi
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

    # Display NVIDIA optimization recommendations
    echo
    log_step "IMPORTANT: NVIDIA Performance Recommendations"
    echo
    log_info "For optimal NVIDIA GPU performance and reliability in Docker containers,"
    log_info "the following kernel parameters are highly recommended:"
    echo
    log_info "\033[1;31msystemd.unified_cgroup_hierarchy=0\033[0m  - Prevents 'CUDA_ERROR_NO_DEVICE' errors in containers"
    log_info "\033[1;31mpcie_port_pm=off\033[0m                    - Disables PCIe power management for better performance"
    log_info "\033[1;31mpcie_aspm.policy=performance\033[0m        - Sets PCIe power state policy to performance mode"
    echo
    log_info "IMPORTANT: If using GPU passthrough to a VM, these parameters should be"
    log_info "added to the GRUB configuration on the BARE METAL HOST, not in the VM."
    echo
    log_info "To add these parameters to your GRUB configuration:"
    log_info "1. Edit /etc/default/grub"
    log_info "2. Add these parameters to GRUB_CMDLINE_LINUX_DEFAULT:"
    log_info "   \033[1;31mExample: GRUB_CMDLINE_LINUX_DEFAULT=\"quiet splash systemd.unified_cgroup_hierarchy=0 pcie_port_pm=off pcie_aspm.policy=performance\"\033[0m"
    log_info "3. Run update-grub (or proxmox-boot-tool refresh on Proxmox)"
    log_info "4. Reboot your system"
    echo

    # Force user acknowledgment
    while true; do
        log_prompt "Type 'I understand' to acknowledge these recommendations: "
        read -r response
        if [[ "$response" == "I understand" ]]; then
            break
        else
            log_warn "Please type 'I understand' to continue"
        fi
    done

    # Check for NVIDIA GPU
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
            if ! prompt_yes_no "This script is designed for Ubuntu $UBUNTU_VERSION, but detected: $PRETTY_NAME. Continue anyway?"; then
                exit 1
            fi
        fi
    fi

    # Install required packages
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
# NVIDIA Driver Selection and Installation
###############################################
select_nvidia_driver() {
    log_step "Selecting NVIDIA driver version..."

    # Check if drivers are already installed
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        log_info "Current NVIDIA installation:"
        nvidia-smi
        if ! prompt_yes_no "NVIDIA driver is already installed. Would you like to reinstall/update it?"; then
            return 0
        fi
    fi

    # Install prerequisites
    log_info "Installing driver prerequisites..."
    apt_install "build-essential dkms linux-headers-$(uname -r) ubuntu-drivers-common pkg-config libglvnd-dev"

    # Detect hardware
    log_info "Detecting NVIDIA hardware..."
    ubuntu-drivers devices | grep -i nvidia

    # Get recommended version
    local recommended_version=$(ubuntu-drivers devices | grep "recommended" | grep -oP 'nvidia-driver-\K[0-9]+' | head -1)

    if [[ -z "$recommended_version" ]]; then
        recommended_version="550"  # Default if we can't detect
    fi

    log_info "Recommended driver version: $recommended_version"

    # Choose installation method
    if prompt_yes_no "Install recommended NVIDIA driver automatically?"; then
        log_info "Installing recommended driver using ubuntu-drivers..."
        if ! run_command "ubuntu-drivers autoinstall"; then
            log_warn "Autoinstall failed, attempting manual installation..."
            if ! apt_install "nvidia-driver-$recommended_version"; then
                log_error "Failed to install NVIDIA driver"
                return 1
            fi
        fi
    else
        # Get driver version from apt cache with no transitional packages
        log_info "Finding available driver versions..."
        log_info "Available NVIDIA driver versions:"
        apt-cache search nvidia-driver- | grep "^nvidia-driver-[0-9]" | grep -v "Transitional package" | sort -V

        # Manual driver selection
        log_prompt "Enter desired driver version number (default: $recommended_version): "
        read -r driver_version
        driver_version=${driver_version:-$recommended_version}

        if [[ -z "$driver_version" ]]; then
            log_error "No driver version specified!"
            return 1
        fi

        # Install the selected driver
        log_info "Installing NVIDIA driver version $driver_version..."
        if ! apt_install "nvidia-driver-$driver_version"; then
            log_error "Failed to install nvidia-driver-$driver_version"
            return 1
        fi
    fi

    # Load the nvidia module if possible
    modprobe nvidia &>/dev/null || log_warn "Could not load nvidia module (normal before reboot)"

    # Check if drivers are working
    if ! nvidia-smi &>/dev/null; then
        log_warn "nvidia-smi not working yet - you may need to reboot"
    else
        log_info "NVIDIA drivers successfully installed!"
    fi

    return 0
}

###############################################
# CUDA Version Selection - Simple Version
###############################################
select_cuda_version() {
    log_step "Selecting CUDA version..."

    # Display available CUDA versions
    log_info "Available CUDA versions:"
    echo "  1. 12.4.0 (default)"
    echo "  2. 12.3.2"
    echo "  3. 12.2.2"
    echo "  4. 12.1.1"
    echo "  5. 12.0.1"
    echo "  6. 11.8.0"
    echo "  7. 11.7.1"
    echo "  8. 11.6.2"
    echo "  9. Other (enter manually)"

    # Get user selection
    log_prompt "Enter your choice [1-9] or press Enter for default: "
    read -r choice

    case "$choice" in
        1|"") CUDA_VERSION="12.4.0" ;;
        2) CUDA_VERSION="12.3.2" ;;
        3) CUDA_VERSION="12.2.2" ;;
        4) CUDA_VERSION="12.1.1" ;;
        5) CUDA_VERSION="12.0.1" ;;
        6) CUDA_VERSION="11.8.0" ;;
        7) CUDA_VERSION="11.7.1" ;;
        8) CUDA_VERSION="11.6.2" ;;
        9)
            log_prompt "Enter CUDA version manually: "
            read -r manual_version
            if [[ -n "$manual_version" ]]; then
                CUDA_VERSION=$manual_version
            fi
            ;;
        *)
            log_warn "Invalid choice, using default version 12.4.0"
            CUDA_VERSION="12.4.0"
            ;;
    esac

    log_info "Selected CUDA version: $CUDA_VERSION"
    return 0
}

###############################################
# Docker Setup
###############################################
setup_docker() {
    log_step "Setting up Docker with NVIDIA support..."

    # Check if Docker is already installed
    if command -v docker >/dev/null 2>&1; then
        log_info "Docker is already installed."
        docker_version=$(docker --version)
        log_info "Current version: $docker_version"
    else
        log_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        chmod +x get-docker.sh
        ./get-docker.sh
        rm get-docker.sh

        # Enable Docker to start on boot
        systemctl enable docker
    fi

    # Fix broken Docker configuration if necessary
    if systemctl status docker 2>&1 | grep -q "Failed to start Docker Application Container Engine"; then
        log_warn "Detected broken Docker configuration. Fixing..."
        systemctl stop docker
        rm -f /etc/docker/daemon.json
        systemctl start docker
    fi

    # Check NVIDIA Docker support
    local need_nvidia_docker=true
    if dpkg -l | grep -q nvidia-docker2; then
        log_info "NVIDIA Docker support is already installed."
        current_version=$(dpkg -l | grep nvidia-docker2 | awk '{print $3}')
        log_info "Current NVIDIA Docker version: $current_version"

        if docker info 2>/dev/null | grep -q "Runtimes:.*nvidia"; then
            log_info "NVIDIA runtime is already configured in Docker."
            need_nvidia_docker=false
        fi
    fi

    if [[ "$need_nvidia_docker" == "true" ]] || prompt_yes_no "Update NVIDIA Docker support?"; then
        log_info "Setting up NVIDIA Container Toolkit..."

        # Install nvidia-container-toolkit
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

    return 0
}

###############################################
# NVIDIA Patches
###############################################
apply_nvidia_patches() {
    log_step "NVIDIA NVENC & NvFBC unlimited sessions patch..."

    if prompt_yes_no "Would you like to patch NVIDIA drivers to remove NVENC session limit?"; then
        # Create temporary directory
        local patch_dir=$(mktemp -d)
        cd "$patch_dir"

        # Download the patch
        log_info "Downloading NVIDIA patcher..."
        run_command "git clone https://github.com/keylase/nvidia-patch.git ."

        # Apply NVENC patch
        log_info "Applying NVENC session limit patch..."
        bash ./patch.sh

        # Apply NvFBC patch if needed
        if prompt_yes_no "Would you also like to patch for NvFBC support (useful for OBS)?"; then
            log_info "Applying NvFBC patch..."
            bash ./patch-fbc.sh
        fi

        # Cleanup
        cd - > /dev/null
        rm -rf "$patch_dir"

        log_info "NVIDIA driver successfully patched!"
    fi

    return 0
}

###############################################
# Docker Configuration for Media
###############################################
configure_docker_for_media() {
    log_step "Configuring Docker for media processing..."

    if prompt_yes_no "Configure Docker with optimized settings for NVIDIA media?"; then
        # Create a daemon.json config
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

        log_info "Docker configured for NVIDIA and media processing"
        log_info "Sample docker-compose created: /opt/docker-templates/plex-nvidia.yml"
    fi

    return 0
}

###############################################
# Check GPU Media Capabilities
###############################################
check_gpu_capabilities() {
    log_step "Checking GPU capabilities for media processing..."

    if ! nvidia-smi --query-gpu=gpu_name --format=csv,noheader > /dev/null 2>&1; then
        log_warn "Cannot check GPU model - driver might not be loaded yet"
        return 0
    fi

    local gpu_model=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader 2>/dev/null)
    log_info "Detected GPU: $gpu_model"

    # Check for encoder/decoder support
    if command -v nvidia-smi > /dev/null; then
        # Check NVENC/NVDEC support
        local nvenc_check=$(nvidia-smi -q | grep -A 4 "Encoder" || echo "")
        local nvdec_check=$(nvidia-smi -q | grep -A 4 "Decoder" || echo "")

        # Get compute capability
        local cuda_capability=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null)

        log_info "GPU Architecture: Compute $cuda_capability"

        if [[ -n "$nvenc_check" ]]; then
            log_info "✓ NVENC (GPU encoding) is supported"
            log_info "  → Compatible with FFmpeg GPU acceleration"
            log_info "  → Compatible with Plex GPU-accelerated encoding"
        else
            log_warn "✗ NVENC not detected - GPU encoding may not be available"
        fi

        if [[ -n "$nvdec_check" ]]; then
            log_info "✓ NVDEC (GPU decoding) is supported"
            log_info "  → Compatible with FFmpeg GPU acceleration"
            log_info "  → Compatible with Plex GPU-accelerated decoding"
        else
            log_warn "✗ NVDEC not detected - GPU decoding may not be available"
        fi
    fi

    # Give compatibility guidance based on GPU model
    if [[ -n "$gpu_model" ]]; then
        case "$gpu_model" in
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
        else
            log_warn "GPU is not yet accessible from Docker - reboot may be needed"
        fi
    fi

    return 0
}

###############################################
# Create Testing Scripts
###############################################
create_test_scripts() {
    log_step "Creating diagnostic and test scripts..."

    # Create directory for test scripts
    mkdir -p /usr/local/bin

    # Docker GPU test script
    cat > /usr/local/bin/test-nvidia-docker.sh <<'EOF'
#!/bin/bash
echo "Testing NVIDIA GPU access inside Docker..."
docker run --rm --gpus all nvidia/cuda:latest nvidia-smi

echo -e "\nTesting FFmpeg with CUDA inside Docker..."
docker run --rm --gpus all nvidia/cuda:latest bash -c "apt-get update >/dev/null && apt-get install -y ffmpeg >/dev/null && ffmpeg -hwaccels | grep cuda"

echo -e "\nTesting NVENC encoding capabilities inside Docker..."
docker run --rm --gpus all nvidia/cuda:latest bash -c "apt-get update >/dev/null && apt-get install -y ffmpeg >/dev/null && ffmpeg -encoders | grep nvenc"
EOF

    # Transcode test script
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

    log_info "Test scripts created:"
    log_info "  • /usr/local/bin/test-nvidia-docker.sh - Test GPU access in Docker"
    log_info "  • /usr/local/bin/test-transcode.sh - Test transcoding performance"

    return 0
}

###############################################
# Main Installation Flow
###############################################
main() {
    log_info "╔══════════════════════════════════════════════════════════════╗"
    log_info "║  NVIDIA Driver and Media Server Setup                        ║"
    log_info "╚══════════════════════════════════════════════════════════════╝"
    log_info "This script will configure NVIDIA drivers and Docker support,"
    log_info "optimized for Plex and FFmpeg hardware acceleration."
    echo

    if ! prompt_yes_no "Ready to begin?"; then
        log_info "Setup cancelled."
        exit 0
    fi

    # Start time for tracking
    start_time=$(date +%s)

    # Run installation steps
    run_preliminary_checks
    select_nvidia_driver
    select_cuda_version
    setup_docker
    apply_nvidia_patches
    configure_docker_for_media
    check_gpu_capabilities
    create_test_scripts

    # Calculate execution time
    end_time=$(date +%s)
    execution_time=$((end_time - start_time))
    minutes=$((execution_time / 60))
    seconds=$((execution_time % 60))

    log_info "╔══════════════════════════════════════════════════════════════╗"
    log_info "║                    Setup Complete!                           ║"
    log_info "║           Completed in ${minutes}m ${seconds}s                              ║"
    log_info "╚══════════════════════════════════════════════════════════════╝"

    # Check if reboot needed
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
