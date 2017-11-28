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
export NET_NAME="${VM_NAME}"
export POOL_NAME=${POOL_NAME:-${WAY}}

source "$my_dir/../../common/virsh/functions"

NODES=( "${VM_NAME}_1" "${VM_NAME}_2" "${VM_NAME}_3" "${VM_NAME}_4" )

function delete_node() {
  local vm_name=$1
  delete_domain $vm_name
  local vol_path=$(get_pool_path $POOL_NAME)
  local vol_name="$vm_name.qcow2"
  if [[ "$ENVIRONMENT_OS" == 'rhel' ]]; then
    rhel_unregister_system $vol_path/$vol_name || true
  fi
  delete_volume $vol_name $POOL_NAME
}

for i in ${NODES[@]} ; do
  delete_node $i
done

delete_network_dhcp $VM_NAME