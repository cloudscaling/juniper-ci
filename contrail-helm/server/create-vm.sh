#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ssh_key_dir="/home/jenkins"

export ENVIRONMENT_OS=${1:-${ENVIRONMENT_OS:-''}}
export OPENSTACK_VERSION=${2:-${OPENSTACK_VERSION:-''}}

export DISK_SIZE=${DISK_SIZE:-'100G'}
export POOL_NAME=${POOL_NAME:-'oshelm'}
export NET_DRIVER=${NET_DRIVER:-'e1000'}
export VM_NAME=${VM_NAME:-"contrail-helm-${ENVIRONMENT_OS}-${OPENSTACK_VERSION}"}

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
  DEFAULT_BASE_IMAGE_NAME="undercloud-${ENVIRONMENT_OS}-${ENVIRONMENT_OS_VERSION}-${OPENSTACK_VERSION}.qcow2"
else
  DEFAULT_BASE_IMAGE_NAME="undercloud-${ENVIRONMENT_OS}-${OPENSTACK_VERSION}.qcow2"
fi
BASE_IMAGE_NAME=${BASE_IMAGE_NAME:-"$DEFAULT_BASE_IMAGE_NAME"}
BASE_IMAGE_DIR=${BASE_IMAGE_DIR:-'/home/root/images'}
mkdir -p ${BASE_IMAGE_DIR}
BASE_IMAGE="${BASE_IMAGE_DIR}/${BASE_IMAGE_NAME}"

if [[ ! -f ${BASE_IMAGE} ]] ; then
  echo "There is no image file ${BASE_IMAGE}"
  exit 1
fi

source "$my_dir/../../common/virsh/functions"

assert_env_exists "$VM_NAME"

# create network
net_name="${VM_NAME}"
if [[ "$ENVIRONMENT_OS" == 'rhel' ]]; then
  net_addr="192.168.301.0"
else
  net_addr="192.168.302.0"
fi
create_network_dhcp $net_name $net_addr

# create pool
create_pool $POOL_NAME

# create hdd
vol_path=$(create_volume "$VM_NAME")

VCPUS=8
MEM='32G'
OS_VARIANT='rhel'
if [[ "$ENVIRONMENT_OS" == 'ubuntu' ]] ; then
  OS_VARIANT='ubuntu'
fi
define_machine $VM_NAME $VCPUS $MEM $OS_VARIANT $net_name $vol_path

# start machine
start_vm $VM_NAME

#TODO: wait machine and get IP via virsh net-dhcp-leases $net_name