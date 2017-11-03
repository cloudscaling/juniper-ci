#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ssh_key_dir="/home/jenkins"

export ENVIRONMENT_OS=${1:-${ENVIRONMENT_OS:-''}}
export OPENSTACK_VERSION=${2:-${OPENSTACK_VERSION:-''}}

export DISK_SIZE=${DISK_SIZE:-'100G'}
export POOL_NAME=${POOL_NAME:-'oshelm'}
export NET_DRIVER=${NET_DRIVER:-'e1000'}
export VM_NAME=${VM_NAME:-"contrail-helm-${ENVIRONMENT_OS}-${OPENSTACK_VERSION}"}

source "$my_dir/../../common/virsh/functions"

delete_domain $VM_NAME
delete_network $VM_NAME

vol_path=$(get_pool_path $POOL_NAME)
vol_name="$VM_NAME.qcow2"
if [[ "$ENVIRONMENT_OS" == 'rhel' ]]; then
  rhel_unregister_system $vol_path/$vol_name || true
fi

delete_volume $vol_name $POOL_NAME

#rm -f "$ssh_key_dir/kp-$NUM" "$ssh_key_dir/kp-$NUM.pub"
#TODO rm keys