#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/../common/${HOST}/ssh-defs"

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

# Set both ZOOKEEPER_PORT and ZOOKEEPER_ANALYTICS_PORT to 2181
# because there is one zookeeper cluster in this test

function setup_k8s() {
  local dest=$1
  local token_opts=${2:-''}
  cat <<EOF | $SSH_WORKER $dest
set -x
export PATH=\${PATH}:/usr/sbin
cd ~/contrail-container-builder
cat <<EOM > common.env
LOG_LEVEL=SYS_DEBUG
CONTRAIL_VERSION=$CONTRAIL_VERSION
KUBERNETES_API_SERVER=$KUBERNETES_API_SERVER
_CONTRAIL_REGISTRY_IP=$DOCKER_REGISTRY_ADDR
OPENSTACK_VERSION=$OPENSTACK_VERSION
CONTROLLER_NODES=$CONTROLLER_NODES
AGENT_NODES=$AGENT_NODES
ZOOKEEPER_PORT=2181
ZOOKEEPER_ANALYTICS_PORT=2181
EOM
cat common.env
kubernetes/setup-k8s.sh $token_opts
# wait docker because ot is restarted at the end for setup-k8s.sh
for (( i=0; i < 10 ; ++i )); do
  echo \"docker wait \${i}/10...\"
  sleep 3
  if docker ps ; then
    echo \"docker wait done\"
    break
  fi
done
EOF
}

token=''
master_dest=''
for d in ${dest[@]} ; do
  setup_k8s $d "join-token=$token" develop
  if [[ -z "$master_dest" ]] ; then
    # first is master, so get token
    master_dest="$d"
    for (( i=0; i < 10; ++i )) ; do
      echo "get k8s cluster token ${i}/10"
      token=$($SSH_WORKER $d "set -x; sudo kubeadm token list | tail -n 1 | awk '{print(\$1)}'")
      if [[ -n "$token" ]] ; then
        echo "get k8s cluster token done: $token"
        break
      fi
      sleep 3
    done
  fi
done

$SSH_WORKER $master_dest  "set -x; export PATH=\${PATH}:/usr/sbin; cd ~/contrail-container-builder/kubernetes/manifests && ./set-node-labels.sh"

