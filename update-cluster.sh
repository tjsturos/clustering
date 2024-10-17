#!/bin/bash
source $HOME/clustering/utils.sh

IS_MASTER=false
# Check if --master option is passed
if [[ "$*" == *"--master"* ]]; then
   IS_MASTER=true
fi

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


link_binaries() {
    echo "Linking binaries"
    LINK_PATH=/usr/local/bin
    if [ -L $LINK_PATH/node ]; then
        sudo rm -f $LINK_PATH/node
    fi
    sudo ln -sf $QUIL_NODE_PATH/$(get_versioned_node) $LINK_PATH/node

    echo "Linking qclient"
    if [ -L $LINK_PATH/qclient ]; then
        sudo rm -f $LINK_PATH/qclient
    fi
    sudo ln -sf $QUIL_CLIENT_PATH/$(get_versioned_qclient) $LINK_PATH/qclient
}


# Main script execution
update_binaries() {
   bash $SCRIPT_DIR/download-binaries.sh
   link_binaries
}

update_binaries

if [ "$IS_MASTER" == "true" ]; then
    ssh_command_to_each_server "cd $HOME/clustering && git pull && bash ~/clustering/update-cluster.sh"
    sudo systemctl daemon-reload
    sudo systemctl restart $QUIL_SERVICE_NAME
fi

sudo systemctl daemon-reload
sudo systemctl restart $QUIL_DATA_WORKER_SERVICE_NAME@*




