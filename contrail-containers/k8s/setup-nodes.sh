#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/../common/${HOST}/ssh-defs"

export KUBERNETES_API_SERVER=${master_ip}
# here we define controller nodes as a ips[0:2]
export CONTROLLER_NODES=$( echo $nodes_cont_ips | sed 's/ /,/g')
# agent nodes are ips [3:]
export AGENT_NODES=$(echo $nodes_comp_ips | sed 's/ /,/g')

function assert_empty() {
  if [[ -z "${!1}" ]] ; then
    echo "ERROR: $1 is empty"
    exit -1
  fi
}
assert_empty KUBERNETES_API_SERVER
assert_empty CONTROLLER_NODES
assert_empty AGENT_NODES

function setup_k8s() {
  local dest=$1
  local token_opts=${2:-''}
  local ssl_opts=''
  if [[ -n "${SSL_ENABLE}" ]] ; then
    ssl_opts="SSL_ENABLE=$SSL_ENABLE"
  fi
  cat <<EOM | $SSH_CMD $SSH_USER@$dest
set -x
export PATH=\${PATH}:/usr/sbin
cd ~/contrail-container-builder
cat <<EOM > common.env
LOG_LEVEL=SYS_DEBUG
CONTRAIL_VERSION=$CONTRAIL_VERSION
KUBERNETES_API_SERVER=$KUBERNETES_API_SERVER
OPENSTACK_VERSION=$OPENSTACK_VERSION
CONTROLLER_NODES=$CONTROLLER_NODES
AGENT_NODES=$AGENT_NODES
AGENT_MODE=$AGENT_MODE
PHYSICAL_INTERFACE=\$(ip route get 1 | grep -o 'dev.*' | awk '{print(\$2)}')
$ssl_opts
EOM
cat common.env
kubernetes/setup-k8s.sh $token_opts
# wait docker because ot is restarted at the end for setup-k8s.sh
for (( i=0; i < 10 ; ++i )); do
  echo \"docker wait \${i}/10...\"
  sleep 5
  if docker ps ; then
    echo \"docker wait done\"
    break
  fi
done
if [[ -n $build_ip ]]; then
  mkdir -p /etc/docker
  cat <<EOF > /etc/docker/daemon.json
{
    "insecure-registries": ["$build_ip:5000"]
}
EOF
EOM
}

token=''
master_dest=''
for node_ip in $nodes_ips ; do
  setup_k8s $node_ip "join-token=$token" develop
  if [[ -z "$master_dest" ]] ; then
    # first is master, so get token
    master_dest="$node_ip"
    for (( i=0; i < 10; ++i )) ; do
      echo "get k8s cluster token ${i}/10"
      token=`$SSH_CMD $SSH_USER@$node_ip "kubeadm token list" | awk '/system:bootstrappers:kubeadm:default-node-token/{print($1)}'`
      if [[ -n "$token" ]] ; then
        echo "get k8s cluster token done: $token"
        break
      fi
      sleep 3
    done
  fi
done

# wait a bit for last node connection establishing
sleep 30
$SSH_CMD $SSH_USER@$master_dest  "set -x; export PATH=\${PATH}:/usr/sbin; cd ~/contrail-container-builder/kubernetes/manifests && ./set-node-labels.sh"
