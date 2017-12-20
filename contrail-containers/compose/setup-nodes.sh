#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/../common/${HOST}/ssh-defs"

dest=( ${SSH_DEST_WORKERS[@]} )
ips=()
for d in ${dest[@]} ; do
  ips+=( $(echo $d | cut -d '@' -f 2))
done
controllers=( ${ips[@]:0:3} )
agents=( ${ips[@]:3} )
export DOCKER_REGISTRY_ADDR=${controllers[0]}
export CONTROLLER_NODES=$(echo ${controllers[@]} | sed 's/ /,/g')
export AGENT_NODES=$(echo ${agents[@]} | sed 's/ /,/g')

function assert_empty() {
  if [[ -z "${!1}" ]] ; then
    echo "ERROR: $1 is empty"
    exit -1
  fi
}
assert_empty DOCKER_REGISTRY_ADDR
assert_empty CONTROLLER_NODES
assert_empty AGENT_NODES

# Set both ZOOKEEPER_PORT and ZOOKEEPER_ANALYTICS_PORT to 2181
# because there is one zookeeper cluster in this test

function setup_node() {
  local host=$1
  cat <<EOF | $SSH_WORKER $host
set -x
export PATH=\${PATH}:/usr/sbin
pushd ~/contrail-container-builder
cat <<EOM > common.env
CONTRAIL_VERSION=$CONTRAIL_VERSION
_CONTRAIL_REGISTRY_IP=$DOCKER_REGISTRY_ADDR
OPENSTACK_VERSION=$OPENSTACK_VERSION
EOM
cat common.env
popd

pushd ~/contrail-ansible-deployer
cat <<EOM > ./inventory/hosts
container_hosts:
  hosts:
EOM
for i in ${ips[@]} ; do
  cat <<EOM >> ./inventory/hosts
    \${i}:
      ansible_ssh_pass: qwe123QWE
EOM
done
cat ./inventory/hosts

cat <<EOM > ./inventory/group_vars/container_hosts.yml
CONTAINER_REGISTRY: ${DOCKER_REGISTRY_ADDR}:5000
contrail_configuration:
  OPENSTACK_VERSION: $OPENSTACK_VERSION
  CONTRAIL_VERSION: $CONTRAIL_VERSION
  CONTROLLER_NODES: $CONTROLLER_NODES
  CLOUD_ORCHESTRATOR: kubernetes
  RABBITMQ_NODE_PORT: 5673
roles:
EOM
for i in ${controllers[@]} ; do
  cat <<EOM >> ./inventory/group_vars/container_hosts.yml
  \${i}:
    configdb:
    config:
    control:
    webui:
    analytics:
    analyticsdb:
EOM
done
for i in ${agents[@]} ; do
  cat <<EOM >> ./inventory/group_vars/container_hosts.yml
  \${i}:
    vrouter:
EOM
done
cat ./inventory/group_vars/container_hosts.yml

cat <<EOM > ./inventory/group_vars/all.yml
BUILD_VMS: false
CONFIGURE_VMS: false
CREATE_CONTAINERS: true
EOM
cat ./inventory/group_vars/all.yml
popd

yum install -y epel-release
yum install -y ansible docker docker-compose

cat <<EOM > /etc/docker/daemon.json
 {
   "insecure-registries": ["${DOCKER_REGISTRY_ADDR}:5000"]
 }
EOM

systemctl enable docker
systemctl restart docker
EOF
}

for d in ${dest[@]} ; do
  setup_node $d
done

