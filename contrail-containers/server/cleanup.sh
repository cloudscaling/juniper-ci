#!/bin/bash -x

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

export ENVIRONMENT_OS=${1:-${ENVIRONMENT_OS:-''}}
export OPENSTACK_VERSION=${2:-${OPENSTACK_VERSION:-''}}

export VM_NAME=${VM_NAME:-"${WAY}-${ENVIRONMENT_OS}-${OPENSTACK_VERSION}"}
export POOL_NAME=${POOL_NAME:-${WAY}}
export NET_DRIVER=${NET_DRIVER:-'e1000'}

source "$my_dir/../../common/virsh/functions"

delete_domain $VM_NAME
delete_network $VM_NAME

vol_path=$(get_pool_path $POOL_NAME)
vol_name="$VM_NAME.qcow2"
if [[ "$ENVIRONMENT_OS" == 'rhel' ]]; then
  rhel_unregister_system $vol_path/$vol_name || true
fi

delete_volume $vol_name $POOL_NAME
