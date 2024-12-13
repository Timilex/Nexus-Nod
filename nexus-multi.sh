#!/bin/bash

echo -e "
▒█▄░▒█ █▀▀ █░█ █░░█ █▀▀ ▒█▀▀█ █▀▀█ █▀▀█ █▀▀█
▒█▒█▒█ █▀▀ ▄▀▄ █░░█ ▀▀█ ▒█░░░ █▄▄▀ █▄▄█ █░░█
▒█░░▀█ ▀▀▀ ▀░▀ ░▀▀▀ ▀▀▀ ▒█▄▄█ ▀░▀▀ ▀░░▀ █▀▀▀
"
sleep 2

BOLD=$(tput bold)
NORMAL=$(tput sgr0)
PINK='\033[1;35m'

show() {
    case $2 in
        "error")
            echo -e "\e[1;31m❌ $1\e[0m"
            ;;
        "progress")
            echo -e "\e[1;34m⏳ $1\e[0m"
            ;;
        "success")
            echo -e "\e[1;32m✅ $1\e[0m"
            ;;
        *)
            echo -e "\e[1;36m🔹 $1\e[0m"
            ;;
    esac
}

PROVER_IDS=("T6EjZ46Bc4WOYQEgxi0uwluJ1HA2" "8etSsGjQrRaD1YpnHIVcnDLkvn92" "TNJ78HaGHHWnL655eUH5nUYZGUR2") # Replace these with your Prover IDs. Example: "fKZPh1AVgsZPHeKI4FR1OXwfJv62"


SERVICE_NAME="nexus"
BASE_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BASE_NEXUS_HOME="$HOME/.nexus-instance"

check_and_install() {
    PACKAGE=$1
    if ! dpkg -l | grep -q "$PACKAGE"; then
        show "$PACKAGE is not installed. Installing..." "progress"
        if ! sudo apt install -y "$PACKAGE"; then
            show "Failed to install $PACKAGE." "error"
            exit 1
        fi
    else
        show "$PACKAGE is already installed."
    fi
}

show "Installing Rust..." "progress"
if ! source <(wget -O - https://raw.githubusercontent.com/zunxbt/installation/main/rust.sh); then
    show "Failed to install Rust." "error"
    exit 1
fi

show "Updating package list..." "progress"
if ! sudo apt update; then
    show "Failed to update package list." "error"
    exit 1
fi

# Check and install required packages
check_and_install git
check_and_install wget
check_and_install build-essential
check_and_install pkg-config
check_and_install libssl-dev
check_and_install unzip

# Loop through each Prover ID and set up a separate instance
for i in "${!PROVER_IDS[@]}"; do
    INSTANCE_ID=$((i + 1))
    INSTANCE_NAME="${SERVICE_NAME}-${INSTANCE_ID}"
    PROVER_ID=${PROVER_IDS[$i]}
    NEXUS_HOME="${BASE_NEXUS_HOME}-${INSTANCE_ID}"

    show "Setting up instance $INSTANCE_ID with Prover ID: $PROVER_ID" "progress"

    # Create a unique NEXUS_HOME directory
    mkdir -p "$NEXUS_HOME"

    # Save the Prover ID to the unique instance's directory
    echo "$PROVER_ID" > "$NEXUS_HOME/prover-id"

    # Clone or update the repository
    REPO_PATH="$NEXUS_HOME/network-api"
    if [ -d "$REPO_PATH" ]; then
        show "$REPO_PATH exists. Updating."
        (cd "$REPO_PATH" && git stash save && git fetch --tags)
    else
        (cd "$NEXUS_HOME" && git clone https://github.com/nexus-xyz/network-api)
    fi

    # Checkout the latest tag
    (cd "$REPO_PATH" && git -c advice.detachedHead=false checkout $(git rev-list --tags --max-count=1))

    # Download and install Protocol Buffers
    cd "$REPO_PATH/clients/cli"
    show "Downloading Protocol Buffers..." "progress"
    if ! wget https://github.com/protocolbuffers/protobuf/releases/download/v21.5/protoc-21.5-linux-x86_64.zip; then
        show "Failed to download Protocol Buffers." "error"
        exit 1
    fi

    show "Extracting Protocol Buffers..." "progress"
    if ! unzip -o protoc-21.5-linux-x86_64.zip -d protoc; then
        show "Failed to extract Protocol Buffers." "error"
        exit 1
    fi

    show "Installing Protocol Buffers..." "progress"
    # Check if the google directory exists and handle conflicts
    if [ -d "/usr/local/include/google" ]; then
        show "Conflict detected in /usr/local/include/google. Cleaning up..." "progress"
        sudo mv /usr/local/include/google /usr/local/include/google_backup || sudo rm -rf /usr/local/include/google
    fi
    
    # Move the new files
    if ! sudo mv protoc/bin/protoc /usr/local/bin/ || ! sudo mv protoc/include/* /usr/local/include/; then
        show "Failed to move Protocol Buffers binaries after cleanup. Please check manually." "error"
        exit 1
    fi


    # Stop and disable the old service if it exists
    if systemctl is-active --quiet "$INSTANCE_NAME.service"; then
        show "$INSTANCE_NAME.service is currently running. Stopping and disabling it..."
        sudo systemctl stop "$INSTANCE_NAME.service"
        sudo systemctl disable "$INSTANCE_NAME.service"
    else
        show "$INSTANCE_NAME.service is not running."
    fi

    # Create a unique systemd service for this instance
    SERVICE_FILE="/etc/systemd/system/${INSTANCE_NAME}.service"
    show "Creating systemd service for instance $INSTANCE_ID..." "progress"
    if ! sudo bash -c "cat > $SERVICE_FILE <<EOF
[Unit]
Description=Nexus XYZ Prover Service Instance $INSTANCE_ID
After=network.target

[Service]
User=$USER
WorkingDirectory=$REPO_PATH/clients/cli
Environment=NEXUS_HOME=$NEXUS_HOME
Environment=NONINTERACTIVE=1
ExecStart=$HOME/.cargo/bin/cargo run --release --bin prover -- beta.orchestrator.nexus.xyz
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF"; then
        show "Failed to create the systemd service file for instance $INSTANCE_ID." "error"
        exit 1
    fi

    # Reload systemd and start the service
    show "Reloading systemd and starting the service for instance $INSTANCE_ID..." "progress"
    if ! sudo systemctl daemon-reload; then
        show "Failed to reload systemd for instance $INSTANCE_ID." "error"
        exit 1
    fi

    if ! sudo systemctl start "$INSTANCE_NAME.service"; then
        show "Failed to start the service for instance $INSTANCE_ID." "error"
        exit 1
    fi

    if ! sudo systemctl enable "$INSTANCE_NAME.service"; then
        show "Failed to enable the service for instance $INSTANCE_ID." "error"
        exit 1
    fi

    show "Instance $INSTANCE_ID setup complete. Logs: journalctl -u $INSTANCE_NAME.service -fn 50"
done

show "All instances set up successfully!"
