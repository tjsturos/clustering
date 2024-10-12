source $HOME/clustering/utils.sh



GIT_SSH_KEY_PATH=$(eval echo $(yq eval '.github_ssh_key_path' $CLUSTER_CONFIG_FILE))

copy_file_to_each_server $GIT_SSH_KEY_PATH ~/.ssh/github_key

ssh_command_to_each_server "chmod 600 ~/.ssh/github_key"

ssh_command_to_each_server "cd ~/clustering && git remote set-url origin git@github.com:tjsturos/clustering.git"

ssh_command_to_each_server "cd ~/clustering && git pull"


