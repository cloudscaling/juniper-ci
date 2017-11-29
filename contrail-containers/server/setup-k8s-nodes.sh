#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/ssh-defs"

dest=( ${SSH_DEST_WORKERS[@]} )
ips=()
for d in ${dest[@]} ; do
  ips+=( $(echo $d | cut -d '@' -f 2))
done
export DOCKER_REGISTRY_ADDR=${ips[0]}
export KUBERNETES_API_SERVER=${ips[0]}
export CONTROLLER_NODES=$(echo ${ips[@]:0:3} | sed 's/ /,/g')
export AGENT_NODES=$(echo ${ips[@]:3} | sed 's/ /,/g')

function assert_empty() {
  if [[ -z "${!1}" ]] ; then
    echo "ERROR: $1 is empty"
    exit -1
  fi
}
assert_empty DOCKER_REGISTRY_ADDR
assert_empty KUBERNETES_API_SERVER
assert_empty CONTROLLER_NODES
assert_empty AGENT_NODES

function setup_k8s() {
  local dest=$1
  local token_opts=${2:-''}
  cat <<EOF | $SSH_WORKER $dest
set -x
sudo mkdir -p /etc/docker
cat <<EOM | sudo tee /etc/docker/daemon.json
{
  \"insecure-registries\": [\"${DOCKER_REGISTRY_ADDR}:5000\"]
}
EOM
if docker version ; then
  sudo service docker restart
fi
cd ~/contrail-container-builder
cat <<EOM > common.env
LOG_LEVEL=SYS_DEBUG
CONTRAIL_VERSION=$CONTRAIL_VERSION
KUBERNETES_API_SERVER=$KUBERNETES_API_SERVER
_CONTRAIL_REGISTRY_IP=$DOCKER_REGISTRY_ADDR
OPENSTACK_VERSION=$OPENSTACK_VERSION
CONTROLLER_NODES=$CONTROLLER_NODES
AGENT_NODES=$AGENT_NODES
EOM
cat common.env
kubernetes/setup-k8s.sh $token_opts
EOF
}

token=''
for d in ${dest[@]} ; do
  setup_k8s $d "join-token=$token"
  if [[ -z "$token" ]] ; then
    # label nodes
    $SSH_WORKER $d "cd ~/contrail-container-builder/kubernetes/manifest && ./set-node-labels.sh"
    # master so get token
    token=$($SSH_WORKER $d "sudo kubeadm token list | tail -n 1 | awk '{print(\$1)}'")
  fi
done
