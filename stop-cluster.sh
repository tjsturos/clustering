source ~/clustering/utils.sh

IS_MASTER=false
DRY_RUN=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --master)
            IS_MASTER=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

stop_local_data_workers() {
    START_CORE_INDEX="$(yq eval '.start_core_index' $CLUSTER_CONFIG_FILE)"
    DATA_WORKER_COUNT="$(yq eval '.data_worker_count' $CLUSTER_CONFIG_FILE)"
    END_CORE_INDEX=$((START_CORE_INDEX + DATA_WORKER_COUNT - 1))


    stop_worker_services $START_CORE_INDEX $END_CORE_INDEX
}

if [ "$IS_MASTER" = true ]; then
    if [ -f "$SSH_CLUSTER_KEY" ]; then
        echo -e "${GREEN}${CHECK_ICON} SSH key found: $SSH_CLUSTER_KEY${RESET}"
    else
        echo -e "${RED}${WARNING_ICON} SSH file: $SSH_CLUSTER_KEY not found!${RESET}"
    fi
    stop_master_service
    stop_local_data_workers
    echo "Stopping services on remote servers..."
    IPS=($(get_cluster_ips))
    for IP in "${IPS[@]}"; do
        REMOTE_USER=$(yq eval ".servers[] | select(.ip == \"$IP\") | .user // \"$DEFAULT_USER\"" $CLUSTER_CONFIG_FILE)
         if ! echo "$(hostname -I)" | grep -q "$IP"; then
            if [ "$DRY_RUN" == "false" ]; then
                echo "Stopping services on $IP ($REMOTE_USER)"

                ssh_to_remote $IP $REMOTE_USER "bash $HOME/clustering/stop-cluster.sh"
            else
                echo "[DRY RUN] Would run stop-cluster.sh on $REMOTE_USER@$IP"
            fi
        fi
    done
else
    stop_local_data_workers
fi


