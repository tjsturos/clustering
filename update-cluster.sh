#!/bin/bash
source $HOME/clustering/utils.sh

IS_MASTER=false
# Check if --master option is passed
if [[ "$*" == *"--master"* ]]; then
   IS_MASTER=true
fi


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
    
    local node_binaries_dir="$QUIL_NODE_PATH"
    local current_version="$1"

    if [ -d "$node_binaries_dir" ]; then
        echo "Checking for old node binaries in $node_binaries_dir"
        for file in "$node_binaries_dir"/*; do
            if [ -f "$file" ]; then
                if [[ "$(basename "$file")" != *"$current_version"* ]]; then
                    if [ "$DRY_RUN" = false ]; then
                        echo "Deleting old binary: $file"
                        rm -f "$file"
                    else
                        echo "[DRY RUN] Would delete old binary: $file"
                    fi
                fi
            fi
        done
        echo "Finished checking for old node binaries."
    else
        echo "Directory $node_binaries_dir does not exist. No files to delete."
    fi
}

delete_old_qclient_binaries() {
    local qclient_binaries_dir="$QUIL_CLIENT_PATH"
    local current_version="$1"

    if [ -d "$qclient_binaries_dir" ]; then
        echo "Checking for old qclient binaries in $qclient_binaries_dir"
        for file in "$qclient_binaries_dir"/*; do
            if [ -f "$file" ]; then
                if [[ "$(basename "$file")" != *"$current_version"* ]]; then
                    if [ "$DRY_RUN" = false ]; then
                        echo "Deleting old binary: $file"
                        rm -f "$file"
                    else
                        echo "[DRY RUN] Would delete old binary: $file"
                    fi
                fi
            fi
        done
        echo "Finished checking for old qclient binaries."
    else
        echo "Directory $qclient_binaries_dir does not exist. No files to delete."
    fi
}



# Main script execution
update_binaries() {
    # Fetch current version
    local release_version=$(fetch_release_version)
    local qclient_release_version=$(fetch_qclient_release_version)
    # Fetch available files
    local available_files=$(fetch_available_files "https://releases.quilibrium.com/release")
    local available_qclient_files=$(fetch_available_files "https://releases.quilibrium.com/qclient-release")

    # Extract the version from the available files
    local available_version=$(echo "$available_files" | grep -oP 'node-([0-9\.]+)+' | head -n 1 | tr -d 'node-')
    local available_qclient_version=$(echo "$available_qclient_files" | grep -oP 'qclient-([0-9\.]+)+' | head -n 1 | tr -d 'node-')

    # Download all matching files if necessary
    download_files "$release_version" "$available_files" $QUIL_NODE_PATH "https://releases.quilibrium.com"
    sudo chmod +x $QUIL_NODE_PATH/$(get_versioned_node)
    download_files "$qclient_release_version" "$available_qclient_files" $QUIL_CLIENT_PATH "https://releases.quilibrium.com"
    sudo chmod +x $QUIL_CLIENT_PATH/$(get_versioned_qclient)

    delete_old_node_binaries "$available_version"
    delete_old_qclient_binaries "$available_qclient_version"
}

update_binaries

if [ "$IS_MASTER" = true ]; then
    update_binaries_on_slave_servers
fi



