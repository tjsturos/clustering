#!/bin/bash

# Get the number of CPU cores
TOTAL_CORES=$(nproc)

# Set default values
DATA_WORKER_COUNT=$TOTAL_CORES
INDEX_START=1
MASTER=false
PARENT_PID=$$
DRY_RUN=false

# Function to display usage information
usage() {
    echo "Usage: $0 [--master] [--dry-run]"
    echo "  --help               Display this help message"
    echo "  --data-worker-count  Number of workers to start (default: number of CPU cores)"
    echo "  --core-index-start   Starting index for worker cores (default: 1)"
    echo "  --dry-run            Dry run mode (default: false)"
    echo "  --master             Run a master node as one of this CPU's cores"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help)
            usage
            ;;
        --data-worker-count)
            DATA_WORKER_COUNT="$2"
            shift 2
            ;;
        --core-index-start)
            INDEX_START="$2"
            shift 2
            ;;
        --master)
            MASTER=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate COUNT
if ! [[ "$DATA_WORKER_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --data-worker-count must be a non-zero unsigned integer"
    exit 1
fi

# Adjust COUNT if master is specified, but only if not all cores are used for workers
if [ "$MASTER" == "true" ] && [ "$TOTAL_CORES" -eq "$DATA_WORKER_COUNT" ]; then
    DATA_WORKER_COUNT=$((TOTAL_CORES - 1))
    echo -e "${BLUE}${INFO_ICON} Adjusting master's data worker count to $DATA_WORKER_COUNT${RESET}"
fi

source $HOME/clustering/utils.sh

if [ "$DRY_RUN" == "true" ]; then
    echo -e "${BLUE}${INFO_ICON} [DRY RUN] Running in dry run mode, no changes will be made${RESET}"
fi

create_data_worker_service_file

if [ "$MASTER" == "true" ]; then
    create_master_service_file
fi

if [ "$DRY_RUN" == "false" ]; then  
    yq eval -i ".start_core_index = $INDEX_START" $CLUSTER_CONFIG_FILE
    yq eval -i ".data_worker_count = $DATA_WORKER_COUNT" $CLUSTER_CONFIG_FILE
else
    echo -e "${BLUE}${INFO_ICON} [DRY RUN] Would set $CLUSTER_CONFIG_FILE's start_core_index to $INDEX_START and data_worker_count to $DATA_WORKER_COUNT${RESET}"
fi

START_CORE_INDEX=$INDEX_START
END_CORE_INDEX=$((INDEX_START + DATA_WORKER_COUNT - 1))

if [ "$DRY_RUN" == "false" ]; then
    sudo systemctl enable $QUIL_SERVICE_NAME.service
    bash -c "sudo systemctl enable $QUIL_DATA_WORKER_SERVICE_NAME\@{$START_CORE_INDEX..$END_CORE_INDEX}"
    sudo systemctl daemon-reload
else
    echo -e "${BLUE}${INFO_ICON} [DRY RUN] Would enable local $QUIL_DATA_WORKER_SERVICE_NAME@{$START_CORE_INDEX..$END_CORE_INDEX}.service${RESET}"
fi

setup_remote_data_workers() {
    local IP=$1
    local USER=$2
    local CORE_INDEX_START=$3  
    local CORE_COUNT=$4
    local TMP_CLUSTER_DIR=$(mktemp -d)

    if [ "$DRY_RUN" == "false" ]; then
        echo -e "${BLUE}${INFO_ICON} Configuring cluster's data workers on $IP ($USER)${RESET}"
    else
        echo -e "${BLUE}${INFO_ICON} [DRY RUN] Would configure cluster's data workers on $IP ($USER)${RESET}"
    fi

    # Use scp to copy the directory to the remote server
    if [ "$DRY_RUN" == "false" ]; then
        # Copy the current directory contents to the temporary directory
        cp -R . "$TMP_CLUSTER_DIR"
        # Check if the clustering repo exists on the remote server
        if ! ssh_to_remote $IP $USER "[ -d $HOME/clustering/.git ]"; then
            # Check if the clustering folder exists
            if ssh_to_remote $IP $USER "[ -d $HOME/clustering ]"; then
                echo -e "${BLUE}${INFO_ICON} Existing clustering folder found on $IP. Removing...${RESET}"
                ssh_to_remote $IP $USER "rm -rf $HOME/clustering"
                echo -e "${GREEN}${SUCCESS_ICON} Successfully removed existing clustering folder on $IP${RESET}"
            fi

            echo -e "${BLUE}${INFO_ICON} Clustering repo not found on $IP. Cloning...${RESET}"
            ssh_to_remote $IP $USER "git clone https://github.com/tjsturos/clustering.git $HOME/clustering"
            ssh_to_remote $IP $USER "chmod +x $HOME/clustering/*.sh"
            copy_cluster_config_to_server
            echo -e "${GREEN}${SUCCESS_ICON} Successfully installed clustering directory to $IP${RESET}"
        else
            echo -e "${GREEN}${CHECK_ICON} Clustering repo found on $IP. Updating...${RESET}"
            ssh_to_remote $IP $USER "cd $HOME/clustering && git pull"
            echo -e "${GREEN}${SUCCESS_ICON} Successfully updated clustering directory to $IP${RESET}"
        fi
      
        # Make all files in the copied directory executable
        echo -e "${GREEN}${SUCCESS_ICON} Made all bash scripts in $HOME/clustering directory executable on $IP${RESET}"
    else
        echo -e "${BLUE}${INFO_ICON} [DRY RUN] Would copy clustering directory to $IP ($USER)${RESET}"
    fi
    
    if [ "$DRY_RUN" == "false" ]; then
        # Log the index start
        echo "Setting up remote server with core index start: $CORE_INDEX_START"
        # Log the core count
        echo "Setting up remote server with core count: $CORE_COUNT"
        ssh_to_remote $IP $USER "bash $HOME/clustering/setup-cluster.sh \
            --core-index-start $CORE_INDEX_START \
            --data-worker-count $CORE_COUNT"
    else
        echo -e "${BLUE}${INFO_ICON} [DRY RUN] Would run setup-cluster.sh on $IP ($USER) with core index start of $CORE_INDEX_START and data worker count of $CORE_COUNT${RESET}"
    fi
}

copy_quil_config_to_server() {
    local ip=$1
    local user=$2
    if [ "$DRY_RUN" == "false" ]; then  
        echo -e "${BLUE}${INFO_ICON} Copying $CLUSTER_CONFIG_FILE to $ip${RESET}"
        ssh_to_remote $IP $USER "mkdir -p $HOME/ceremonyclient/node/.config" 
        scp_to_remote "$QUIL_CONFIG_FILE $user@$ip:$HOME/ceremonyclient/node/.config/config.yml"
    else
        echo -e "${BLUE}${INFO_ICON} [DRY RUN] Would copy $QUIL_CONFIG_FILE to $ip ($user)${RESET}"
    fi
}

copy_cluster_config_to_server() {
    local ip=$1
    local user=$2
    if [ "$DRY_RUN" == "false" ]; then  
        echo -e "${BLUE}${INFO_ICON} Copying $CLUSTER_CONFIG_FILE to $ip${RESET}"
        ssh_to_remote $IP $USER "mkdir -p $HOME/clustering" 
        scp_to_remote "$CLUSTER_CONFIG_FILE $user@$ip:$HOME/clustering/cluster.yaml"
    else
        echo -e "${BLUE}${INFO_ICON} [DRY RUN] Would copy $CLUSTER_CONFIG_FILE to $ip ($user)${RESET}"
    fi
}
# Start the master and update the config
if [ "$MASTER" == "true" ]; then
    if [ -f "$SSH_CLUSTER_KEY" ]; then
        echo -e "${GREEN}${CHECK_ICON} SSH key found: $SSH_CLUSTER_KEY${RESET}"
    else
        echo -e "${RED}${WARNING_ICON} SSH file: $SSH_CLUSTER_KEY not found!${RESET}"
    fi
    update_quil_config $DRY_RUN

    servers=$(yq eval '.servers' $CLUSTER_CONFIG_FILE)
    server_count=$(echo "$servers" | yq eval '. | length' -)

    # create a temporary directory for the files to be copied
    TMP_CLUSTER_DIR=$(mktemp -d)
    REMOTE_INDEX_START=$INDEX_START

    for ((i=0; i<$server_count; i++)); do
        server=$(yq eval ".servers[$i]" $CLUSTER_CONFIG_FILE)
        ip=$(echo "$server" | yq eval '.ip' -)
        remote_user=$(echo "$server" | yq eval ".user // \"$DEFAULT_USER\"" -)
        data_worker_count=$(echo "$server" | yq eval '.data_worker_count // "false"' -)

        if echo "$(hostname -I)" | grep -q "$ip"; then
            available_cores=$(($(nproc) - 1))
        else
            echo "Getting available cores for $ip (user: $remote_user)"
            # Get the number of available cores
            available_cores=$(ssh_to_remote $ip $remote_user "nproc")
        fi

        if [ "$data_worker_count" == "false" ] || [ "$data_worker_count" -gt "$available_cores" ]; then
            data_worker_count=$available_cores
            echo "Setting data_worker_count to available cores: $data_worker_count"
        fi

        echo -e "${BLUE}${INFO_ICON} Configuring server $remote_user@$ip with $data_worker_count data workers${RESET}"

        if ! echo "$(hostname -I)" | grep -q "$ip"; then
            copy_quil_config_to_server "$ip" "$remote_user"
            copy_cluster_config_to_server
            setup_remote_data_workers "$ip" "$remote_user" "$REMOTE_INDEX_START" "$data_worker_count" "$TMP_CLUSTER_DIR" &
        fi
        REMOTE_INDEX_START=$((REMOTE_INDEX_START + data_worker_count))
    done

    # clean up the temporary directory
    rm -rf "$TMP_CLUSTER_DIR"
fi

wait