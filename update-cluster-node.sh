#!/bin/bash
source $HOME/clustering/utils.sh

download_files() {
  local available_version=$1
  local file_list=$2
  local dest_path=$3
  local base_url=$4

  while IFS= read -r file; do
    # only download files that are for this architecture
    if [[ "$file" == *"$OS_ARCH"* ]]; then
      local file_url="${base_url}/${file}"
      mkdir -p $dest_path
      local dest_file="${dest_path}/${file}"

      if [ ! -f "$dest_file" ]; then
          log "Downloading $file_url to $dest_file"
          curl -o "$dest_file" "$file_url"
      else
          log "File $dest_file already exists"
      fi
    fi
  done <<< "$file_list"
}

fetch_release_version() {
    local RELEASE_VERSION="$(curl -s https://releases.quilibrium.com/release | grep -oP "\-([0-9]+\.?)+\-" | head -n 1 | tr -d 'node-')"
    echo $RELEASE_VERSION
}

fetch_qclient_release_version() {
    local RELEASE_VERSION="$(curl -s https://releases.quilibrium.com/qclient-release | grep -oP "\-([0-9]+\.?)+\-" | head -n 1 | tr -d 'qclient-')"
    echo $RELEASE_VERSION
}

fetch_available_files() {
  local url=$1
  curl -s "$url"
}

get_versioned_node() {
    echo "node-$(fetch_release_version)-$(get_os_arch)"
}

get_versioned_qclient() {
    echo "qclient-$(fetch_qclient_release_version)-$(get_os_arch)"
}

# Define current directory and set to variable
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

delete_old_node_binaries() {
    local node_binaries_dir="$SCRIPT_DIR/node_binaries"
    
    if [ -d "$node_binaries_dir" ]; then
        echo "Deleting files in $node_binaries_dir"
        if [ "$DRY_RUN" = false ]; then
            rm -f "$node_binaries_dir"/*
            echo "All files in $node_binaries_dir have been deleted."
        else
            echo "[DRY RUN] Would delete all files in $node_binaries_dir"
        fi
    else
        echo "Directory $node_binaries_dir does not exist. No files to delete."
    fi
}

delete_old_qclient_binaries() {
    local node_binaries_dir="$SCRIPT_DIR/node_binaries"
    
    if [ -d "$node_binaries_dir" ]; then
        echo "Deleting files in $node_binaries_dir"
        if [ "$DRY_RUN" = false ]; then
            rm -f "$node_binaries_dir"/*
            echo "All files in $node_binaries_dir have been deleted."
        else
            echo "[DRY RUN] Would delete all files in $node_binaries_dir"
        fi
    else
        echo "Directory $node_binaries_dir does not exist. No files to delete."
    fi
}

delete_old_node_binaries
delete_old_qclient_binaries

# Main script execution
get_new_binaries() {
    # Fetch current version
    local release_version=$(fetch_release_version)
    # Fetch available files
    local available_files=$(fetch_available_files "https://releases.quilibrium.com/release")
    local available_qclient_files=$(fetch_available_files "https://releases.quilibrium.com/qclient-release")

    # Extract the version from the available files
    local available_version=$(echo "$available_files" | grep -oP 'node-([0-9\.]+)+' | head -n 1 | tr -d 'node-')
    local available_qclient_version=$(echo "$available_qclient_files" | grep -oP 'qclient-([0-9\.]+)+' | head -n 1 | tr -d 'node-')

    # Download all matching files if necessary
    download_files "$release_version" "$available_files" $SCRIPT_DIR/node_binaries "https://releases.quilibrium.com"
    sudo chmod +x $SCRIPT_DIR/node_binaries/$(get_versioned_node)
    download_files "$release_version" "$available_qclient_files" $SCRIPT_DIR/qclient_binaries "https://releases.quilibrium.com"
    sudo chmod +x $SCRIPT_DIR/qclient_binaries/$(get_versioned_qclient)
}

get_new_binaries

# Copy new binaries to each server in the cluster
copy_binaries_to_servers() {
    local cluster_ips=($(get_cluster_ips))
    local NODE_BINARIES_DIR="$SCRIPT_DIR/node_binaries"
    local QCLIENT_BINARIES_DIR="$SCRIPT_DIR/qclient_binaries"

    
    local NODE_BINARY_NAME="$(get_versioned_node)"
    local QCLIENT_BINARY_NAME="$(get_versioned_qclient)"

    for ip in "${cluster_ips[@]}"; do
        local user=$(yq eval ".servers[] | select(.ip == \"$ip\") | .user // \"$DEFAULT_USER\"" "$CLUSTER_CONFIG_FILE")
        
        echo "Copying binaries to $user@$ip..."
        if [ "$DRY_RUN" = false ]; then
            ssh_to_remote $ip $user "mkdir -p $QUIL_NODE_PATH $QUIL_CLIENT_PATH"
            echo "Created directories on $ip"
            scp_to_remote "$NODE_BINARIES_DIR/* $user@$ip:$QUIL_NODE_PATH/"
            scp_to_remote "$QCLIENT_BINARIES_DIR/* $user@$ip:$QUIL_CLIENT_PATH/"
            ssh_to_remote $ip $user "chmod +x $QUIL_NODE_PATH/$NODE_BINARY_NAME $QUIL_CLIENT_PATH/$QCLIENT_BINARY_NAME"
            echo "Binaries copied and permissions set for $ip"
        else
            echo "[DRY RUN] Would copy $NODE_BINARY_NAME and $QCLIENT_BINARY_NAME to $user@$ip and set execute permissions"
        fi
    done
}

copy_binaries_to_servers



