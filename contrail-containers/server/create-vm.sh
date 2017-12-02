#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [[ -z "$WORKSPACE" ]] ; then
  echo "WORKSPACE variable is expected"
  exit -1
fi

if [[ -z "$WAY" ]] ; then
  echo "WAY variable is expected: oshelm/k8s"
  exit -1
fi

export ENV_FILE="$WORKSPACE/cloudrc"

export VM_NAME=${VM_NAME:-"${WAY}-${ENVIRONMENT_OS}-${OPENSTACK_VERSION}"}
export NET_NAME="${VM_NAME}"
export DISK_SIZE=${DISK_SIZE:-'128'}
export POOL_NAME=${POOL_NAME:-${WAY}}
export NET_DRIVER=${NET_DRIVER:-'e1000'}
export BRIDGE_NAME=${BRIDGE_NAME:-${WAY}}

VCPUS=4
MEM=8192
OS_VARIANT='rhel7'

if [[ -z "$ENVIRONMENT_OS" ]] ; then
  echo "ENVIRONMENT_OS is expected (e.g. export ENVIRONMENT_OS=centos)"
  exit 1
fi

if [[ -z "$OPENSTACK_VERSION" ]] ; then
  echo "OPENSTACK_VERSION is expected (e.g. export OPENSTACK_VERSION=ocata)"
  exit 1
fi

if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  if [[ -z "$RHEL_ACCOUNT_FILE" ]] ; then
    echo "ERROR: for rhel environemnt the environment variable RHEL_ACCOUNT_FILE is required"
    exit 1
  fi
fi

# base image for VMs
if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  DEFAULT_BASE_IMAGE_NAME="${WAY}-${ENVIRONMENT_OS}-${ENVIRONMENT_OS_VERSION}-${OPENSTACK_VERSION}.qcow2"
else
  DEFAULT_BASE_IMAGE_NAME="${WAY}-${ENVIRONMENT_OS}-${OPENSTACK_VERSION}.qcow2"
fi
BASE_IMAGE_NAME=${BASE_IMAGE_NAME:-"$DEFAULT_BASE_IMAGE_NAME"}
BASE_IMAGE_POOL=${BASE_IMAGE_POOL:-'images'}
BASE_IMAGE_DIR=${BASE_IMAGE_DIR:-'/home/root/images'}
BASE_IMAGE="${BASE_IMAGE_DIR}/${BASE_IMAGE_NAME}"

if [[ ! -f ${BASE_IMAGE} ]] ; then
  echo "There is no image file ${BASE_IMAGE}"
  exit 1
fi

source "$my_dir/../../common/virsh/functions"

NODES=( "${VM_NAME}_1" "${VM_NAME}_2" "${VM_NAME}_3" "${VM_NAME}_4" )
for i in ${NODES[@]} ; do
  assert_env_exists "$i"
done

# re-create network
delete_network_dhcp $NET_NAME
if [[ "$ENVIRONMENT_OS" == 'rhel' ]]; then
  net_addr="192.168.221.0"
else
  net_addr="192.168.222.0"
fi
create_network_dhcp $NET_NAME $net_addr $BRIDGE_NAME

# create pool
create_pool $POOL_NAME

# re-create disk
function define_node() {
  local vm_name=$1
  local vol_name=$vm_name
  delete_volume $vol_name $POOL_NAME
  local vol_path=$(create_volume_from $vol_name $POOL_NAME $BASE_IMAGE_NAME $BASE_IMAGE_POOL)

  if [[ "$ENVIRONMENT_OS" == 'ubuntu' ]] ; then
    OS_VARIANT='ubuntu'
  fi
  define_machine $vm_name $VCPUS $MEM $OS_VARIANT $NET_NAME $vol_path $DISK_SIZE
}

for i in ${NODES[@]} ; do
  define_node "$i"
done

# customize domain to set root password
# TODO: access denied under non root...
# customized manually for now
#for i in ${NODES[@]} ; do
#  domain_customize $i ${WAY}.local
#done

# start nodes
for i in ${NODES[@]} ; do
  start_vm $i
done

#wait machine and get IP via virsh net-dhcp-leases $NET_NAME
ips=( $(wait_dhcp $NET_NAME ) )
for ip in ${ips[@]} ; do
  wait_ssh $ip
done

# prepare host name
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30"
index=0
for ip in ${ips[@]} ; do
  (( index+=1 ))
  cat <<EOF | ssh $SSH_OPTS root@${ip}
set -x
hname="node-\$(echo $ip | tr '.' '-')"
echo \$hname > /etc/hostname
hostname \$hname
domainname localdomain
echo ${ip}  \${hname}.localdomain  \${hname} >> /etc/hosts
EOF
done

# first machine is master
master_ip=${ips[0]}

# save env file
cat <<EOF >$ENV_FILE
SSH_USER=stack
public_ip=$master_ip
public_ip_build=$master_ip
public_ip_helm=$master_ip
ssh_key_file=/home/jenkins/.ssh/id_rsa
nodes="${NODES[@]}"
nodes_ips="${ips[@]}"
EOF
