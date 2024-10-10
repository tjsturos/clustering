BLUE="\e[34m"
INFO_ICON="\u2139"
RESET="\e[0m"
RED="\e[31m"
WARNING_ICON="\u26A0"
GREEN="\e[32m"
CHECK_ICON="\u2705"
echo "Loading utils file..."

get_os_arch() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch=$(uname -m)

    case "$os" in
        linux|darwin) ;;
        *) echo "Unsupported operating system: $os" >&2; return 1 ;;
    esac

    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *) echo "Unsupported architecture: $arch" >&2; return 1 ;;
    esac

    echo "${os}-${arch}"
}

export OS_ARCH="$(get_os_arch)"

install_yq() {
    # Check if yq is installed
    if ! command -v yq &> /dev/null
    then
        echo -e "${BLUE}${INFO_ICON} yq is not installed. Installing yq...${RESET}"
        if [ "$DRY_RUN" == "false" ]; then
            if [ -f "./install-yq.sh" ]; then
                bash ./install-yq.sh
            else
                echo "Error: install-yq.sh script not found in the current directory."
                exit 1
            fi
        else
            echo "Dry run: Would run ./install-yq.sh to install yq"
        fi
    else
        echo -e "${GREEN}${CHECK_ICON} yq is already installed.${RESET}"
    fi
}

install_yq

CLUSTER_CONFIG_FILE="$HOME/clustering/cluster.yaml"

# Check if cluster config file exists
if [ ! -f "$CLUSTER_CONFIG_FILE" ]; then
    echo -e "${RED}${WARNING_ICON} Error: Cluster configuration file not found at $CLUSTER_CONFIG_FILE${RESET}"
    exit 1
fi

export NODE_BINARY_NAME="$(yq eval '.node_binary_name' $CLUSTER_CONFIG_FILE)"
export QUIL_NODE_PATH=$(eval echo "$(yq eval '.quilibrium_node_path // "$HOME/ceremonyclient/node"' $CLUSTER_CONFIG_FILE)")
export QUIL_CLIENT_PATH=$(eval echo "$(yq eval '.quilibrium_client_path // "$HOME/ceremonyclient/client"' $CLUSTER_CONFIG_FILE)")
export QUIL_SERVICE_NAME=$(eval echo "$(yq eval '.master_service_name // "ceremonyclient"' $CLUSTER_CONFIG_FILE)")
export QUIL_CONFIG_DIR=$(eval echo "$(yq eval '.quilibrium_config_dir // "$HOME/ceremonyclient/node/.config"' $CLUSTER_CONFIG_FILE)")
export QUIL_CONFIG_FILE="$QUIL_CONFIG_DIR/config.yml"
export QUIL_DATA_WORKER_SERVICE_NAME="$(yq eval '.data_worker_service_name // "dataworker"' $CLUSTER_CONFIG_FILE)"

export SSH_CLUSTER_KEY=$(eval echo $(yq eval '.ssh_key_path // "$HOME/.ssh/cluster-key"' $CLUSTER_CONFIG_FILE))
export DEFAULT_USER=$(eval echo $(yq eval '.default_user // "ubuntu"' $CLUSTER_CONFIG_FILE))
export SSH_PORT="$(yq eval '.ssh_port // "22"' $CLUSTER_CONFIG_FILE)"

echo -e "${BLUE}${INFO_ICON} DEFAULT_USER: $DEFAULT_USER${RESET}"

# Get the maximum number of CPU cores
MAX_CORES=$(nproc)

ssh_to_remote() {
    local IP=$1
    local USER=$2
    local COMMAND=$3
    shift 2

    if [ "$DRY_RUN" == "false" ]; then
        ssh -i $SSH_CLUSTER_KEY -q -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USER@$IP" "$COMMAND"
    else
        echo "[DRY RUN] Would run: ssh -i $SSH_CLUSTER_KEY -q -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $USER@$IP $COMMAND"
    fi
}

scp_to_remote() {
    local FILE_ARGS=$1

    if [ "$DRY_RUN" == "false" ]; then
        scp -i $SSH_CLUSTER_KEY -P $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $FILE_ARGS
    else
        echo "[DRY RUN] Would run: scp -i $SSH_CLUSTER_KEY -P $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $FILE_ARGS"
    fi
}

MASTER_SERVICE_FILE="/etc/systemd/system/$QUIL_SERVICE_NAME.service"
DATA_WORKER_SERVICE_FILE="/etc/systemd/system/$QUIL_DATA_WORKER_SERVICE_NAME@.service"
create_master_service_file() {
    USER=$(whoami)
    GROUP=$(id -gn)
    if [ -z "$USER" ] || [ -z "$GROUP" ]; then
        echo "Error: Failed to get user or group information"
        exit 1
    fi
    echo -e "${BLUE}${INFO_ICON} Updating $QUIL_SERVICE_NAME.service file...${RESET}"
    local temp_file=$(mktemp)   

    cat > "$temp_file" <<EOF
[Unit]
Description=Quilibrium Master Node Service
After=network.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=5
StartLimitBurst=5
User=$USER
WorkingDirectory=$QUIL_NODE_PATH
ExecStart=$QUIL_NODE_PATH/$NODE_BINARY_NAME
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
EOF

    if [ "$DRY_RUN" == "true" ]; then
        echo -e "${BLUE}${INFO_ICON} [DRY RUN] Would create master service file ($service_file) with the following content:${RESET}"
        cat "$temp_file"
        rm "$temp_file"
    else
        sudo mv "$temp_file" "$MASTER_SERVICE_FILE"
        sudo systemctl daemon-reload
        echo -e "${BLUE}${INFO_ICON} Service file created and systemd reloaded.${RESET}"
    fi
}

start_master_service() {
    sudo systemctl start $QUIL_SERVICE_NAME
}   

stop_master_service() {
    sudo systemctl stop $QUIL_SERVICE_NAME
}

status_master_service() {
    sudo systemctl status $QUIL_SERVICE_NAME
}

create_data_worker_service_file() {
   
    USER=$(whoami)
    if [ -z "$USER" ]; then
        echo "Error: Failed to get user information"
        exit 1
    fi
    echo -e "${BLUE}${INFO_ICON} Updating $DATA_WORKER_SERVICE_FILE file...${RESET}"
    local temp_file=$(mktemp)
    
    cat > "$temp_file" <<EOF
[Unit]
Description=Quilibrium Worker Service %i
After=network.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=$QUIL_NODE_PATH
Restart=on-failure
RestartSec=5
StartLimitBurst=5
User=$USER
ExecStart=$QUIL_NODE_PATH/$NODE_BINARY_NAME --core %i
KillSignal=SIGINT

[Install]
WantedBy=multi-user.target
EOF

    if [ "$DRY_RUN" == "true" ]; then
        echo -e "${BLUE}${INFO_ICON} [DRY RUN] Would create data worker service file ($service_file) with the following content:${RESET}"
        cat "$temp_file"
        rm "$temp_file"
    else
        sudo mv "$temp_file" "$DATA_WORKER_SERVICE_FILE"
        sudo systemctl daemon-reload
        echo -e "${BLUE}${INFO_ICON} Service file created and systemd reloaded.${RESET}"
    fi
}

create_service_file_if_not_exists() {
    local service_file=$1
    local create_function=$2

    if [ ! -f "$service_file" ]; then
        echo -e "${BLUE}${INFO_ICON} Service file $service_file does not exist. Creating it...${RESET}"
        $create_function
    else
        echo -e "${GREEN}${CHECK_ICON} Service file $service_file already exists.${RESET}"
    fi
    sudo systemctl daemon-reload
}

create_service_file_if_not_exists "$DATA_WORKER_SERVICE_FILE" create_data_worker_service_file

enable_worker_services() {
    local START_CORE_INDEX=$1
    local END_CORE_INDEX=$2
    # start the master node
    bash -c "sudo systemctl enable $QUIL_DATA_WORKER_SERVICE_NAME\@{$START_CORE_INDEX..$END_CORE_INDEX}"
}

disabled_worker_services() {
    local START_CORE_INDEX=$1
    local END_CORE_INDEX=$2
    # start the master node
    bash -c "sudo systemctl disable $QUIL_DATA_WORKER_SERVICE_NAME\@{$START_CORE_INDEX..$END_CORE_INDEX}"
}

start_worker_services() {
    local START_CORE_INDEX=$1
    local END_CORE_INDEX=$2
    # start the master node
    enable_worker_services $START_CORE_INDEX $END_CORE_INDEX
    bash -c "sudo systemctl start $QUIL_DATA_WORKER_SERVICE_NAME\@{$START_CORE_INDEX..$END_CORE_INDEX}"
}

stop_worker_services() {
    local START_CORE_INDEX=$1
    local END_CORE_INDEX=$2
    # stop the master node
    disabled_worker_services $START_CORE_INDEX $END_CORE_INDEX
    bash -c "sudo systemctl stop $QUIL_DATA_WORKER_SERVICE_NAME\@{$START_CORE_INDEX..$END_CORE_INDEX}"
}

get_cluster_ips() {
    local config=$(yq eval . $CLUSTER_CONFIG_FILE)
    local servers=$(echo "$config" | yq eval '.servers' -)
    local server_count=$(echo "$servers" | yq eval '. | length' -)
    local ips=()

    for ((i=0; i<server_count; i++)); do
        local server=$(echo "$servers" | yq eval ".[$i]" -)
        local ip=$(echo "$server" | yq eval '.ip' -)
        
        if [ -n "$ip" ] && [ "$ip" != "null" ]; then
            ips+=("$ip")
        fi
    done

    echo "${ips[@]}"
}

start_remote_server_services() {
    local config=$(yq eval . $CLUSTER_CONFIG_FILE)
    local servers=$(echo "$config" | yq eval '.servers' -)
    local server_count=$(echo "$servers" | yq eval '. | length' -)

    for ((i=0; i<server_count; i++)); do
        local server=$(echo "$servers" | yq eval ".[$i]" -)
        local ip=$(echo "$server" | yq eval '.ip' -)
        local remote_user=$(echo "$server" | yq eval ".user // \"$DEFAULT_USER\"" -)
        
        if [ -n "$ip" ] && [ "$ip" != "null" ]; then
            if [ "$DRY_RUN" == "false" ]; then
                if ! echo "$(hostname -I)" | grep -q "$ip"; then
                    echo "Starting services on $ip"
                    ssh_to_remote $ip $remote_user "bash $HOME/clustering/start-cluster.sh"
                fi
            else
                echo "[DRY RUN] Would run $HOME/clustering/start-cluster.sh on $remote_user@$ip"
            fi
        fi
    done
}

update_quil_config() {
    config=$(yq eval . $CLUSTER_CONFIG_FILE)
    
    # Get the array of servers
    servers=$(echo "$config" | yq eval '.servers' -)

    # Clear the existing dataWorkerMultiaddrs array
    if [ "$DRY_RUN" == "false" ]; then
        yq eval -i '.engine.dataWorkerMultiaddrs = []' "$QUIL_CONFIG_FILE"
    else
        echo -e "${BLUE}${INFO_ICON} [DRY RUN] Would clear $QUIL_CONFIG_FILE's $dataWorkerMultiaddrs${RESET}"
    fi

    # Initialize TOTAL_EXPECTED_DATA_WORKERS
    TOTAL_EXPECTED_DATA_WORKERS=0

    # Get the number of servers
    server_count=$(echo "$servers" | yq eval '. | length' -)

    SERVER_CORE_INDEX_START=0
    SERVER_CORE_INDEX_END=0
    # Loop through each server
    for ((i=0; i<server_count; i++)); do
        server=$(echo "$servers" | yq eval ".[$i]" -)
        ip=$(echo "$server" | yq eval '.ip' -)
        remote_user=$(echo "$server" | yq eval ".user // \"$DEFAULT_USER\"" -)
        data_worker_count=$(echo "$server" | yq eval '.data_worker_count // "false"' -)
        available_cores=$(nproc)
        
        
        # Skip invalid entries
        if [ -z "$ip" ] || [ "$ip" == "null" ]; then
            echo "Skipping invalid server entry: $server"
            continue
        fi

        echo "Processing server: $ip (user: $remote_user, worker count: $data_worker_count)"
        if echo "$(hostname -I)" | grep -q "$ip"; then
            if [ "$DRY_RUN" == "false" ]; then
                yq eval -i ".main_ip = \"$ip\"" $CLUSTER_CONFIG_FILE
                echo "Set main IP to $ip in clustering configuration"
            else
                echo "[DRY RUN] Would set main IP to $ip in clustering configuration"
            fi
            # This is the master server, so subtract 1 from the total core count
            available_cores=$(($(nproc) - 1))
        else
            echo "Getting available cores for $ip (user: $remote_user)"
            # Get the number of available cores
            available_cores=$(ssh_to_remote $ip $remote_user nproc)
        fi

        if [ "$data_worker_count" == "false" ]; then
            data_worker_count=$available_cores
        fi
        # Convert data_worker_count to integer and ensure it's not greater than available cores
        data_worker_count=$(echo "$data_worker_count" | tr -cd '0-9')
        data_worker_count=$((data_worker_count > 0 ? data_worker_count : available_cores))
        data_worker_count=$((data_worker_count < available_cores ? data_worker_count : available_cores))

        echo "Data worker count for $ip: $data_worker_count"
        
        # Increment the global count
        TOTAL_EXPECTED_DATA_WORKERS=$((TOTAL_EXPECTED_DATA_WORKERS + data_worker_count))
        # Calculate the starting port for this server
        starting_port=$((40000 + SERVER_CORE_INDEX_START))
        
        if [ "$DRY_RUN" == "true" ]; then
            echo -e "${BLUE}${INFO_ICON} [DRY RUN] Starting port for $ip: $starting_port${RESET}"
        fi

        for ((j=0; j<data_worker_count; j++)); do
            port=$((starting_port + j))
            addr="/ip4/$ip/tcp/$port"
            if [ "$DRY_RUN" == "false" ]; then
                yq eval -i ".engine.dataWorkerMultiaddrs += \"$addr\"" "$QUIL_CONFIG_FILE"
            fi
            SERVER_CORE_INDEX_END=$((SERVER_CORE_INDEX_END + 1))
        done
        
        # Calculate the end port for this server
        
        if [ "$DRY_RUN" == "true" ]; then
            end_port=$((40000 + $SERVER_CORE_INDEX_END - 1))
            echo -e "${BLUE}${INFO_ICON} [DRY RUN] Ending port for $ip: $end_port${RESET}"
        fi
        
        if [ "$DRY_RUN" == "false" ]; then
            # Count total lines with this IP
            total_lines=$(yq eval '.engine.dataWorkerMultiaddrs[] | select(contains("'$ip'"))' "$QUIL_CONFIG_FILE" | wc -l)
        
            echo "Server $ip:  Total lines: $total_lines, Expected data workers: $data_worker_count"
            if [ "$total_lines" -ne "$data_worker_count" ]; then
                echo -e "\e[33mWarning: Mismatch detected for server $ip\e[0m"
                echo -e "\e[33m  - Expected $data_worker_count data workers, found $total_lines\e[0m"
            fi
        else
            echo "[DRY RUN] Would count total lines with this IP: $ip (expected $data_worker_count)"
        fi
        
        SERVER_CORE_INDEX_START=$((SERVER_CORE_INDEX_END))
    done

    if [ "$DRY_RUN" == "false" ]; then
        # Print out the number of data worker multiaddrs
        actual_data_workers=$(yq eval '.engine.dataWorkerMultiaddrs | length' "$QUIL_CONFIG_FILE")

        if [ "$TOTAL_EXPECTED_DATA_WORKERS" -ne "$actual_data_workers" ]; then
            echo -e "\e[33mWarning: The number of data worker multiaddrs in the config doesn't match the expected count.\e[0m"
            echo -e "${BLUE}${INFO_ICON} Data workers to be started: $TOTAL_EXPECTED_DATA_WORKERS${RESET}"
            echo -e "${BLUE}${INFO_ICON} Actual data worker multiaddrs in config: $actual_data_workers${RESET}"
        else
            echo -e "${BLUE}${INFO_ICON} Number of actual data workers found ($actual_data_workers) matches the expected amount.${RESET}"
        fi
    else 
        echo -e "${BLUE}${INFO_ICON} [DRY RUN] Would update data worker multiaddrs to have $TOTAL_EXPECTED_DATA_WORKERS data workers${RESET}"
    fi
}


