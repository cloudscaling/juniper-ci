#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [[ -z "$NUM" ]]; then
  echo "NUM variable is expected"
  exit -1
fi
if [[ -z "$(echo $NUM | grep '^[1-9][0-9]$')" ]]; then
  echo "NUM value must be in range from 10 to 99"
  exit -1
fi
if [[ -z "$WORKSPACE" ]] ; then
  echo "WORKSPACE variable is expected"
  exit -1
fi
if [[ -z "$WAY" ]] ; then
  echo "WAY variable is expected: helm/k8s/kolla/ansible"
  exit -1
fi

export ENVIRONMENT_OS=${1:-${ENVIRONMENT_OS:-''}}
export OPENSTACK_VERSION=${2:-${OPENSTACK_VERSION:-''}}

source "$my_dir/../../../common/virsh/functions"
source "$my_dir/setup-defs"
source "$my_dir/definitions"

function delete_node() {
  local vm_name=$1
  delete_domain $vm_name
  local vol_path=$(get_pool_path $POOL_NAME)
  local vol_name="$vm_name.qcow2"
  if [[ "$ENVIRONMENT_OS" == 'rhel' ]]; then
    rhel_unregister_system $vol_path/$vol_name || true
  fi
  delete_volume $vol_name $POOL_NAME
  local index=0
  for ((; index<10; ++index)); do
    delete_volume "$vm_name-$index.qcow2" $POOL_NAME
  done
}

for i in `virsh list --all | grep $VM_NAME | awk '{print $2}'` ; do
  delete_node $i
done
delete_network_dhcp $NET_NAME
delete_network_dhcp ${NET_NAME}_1
delete_network_dhcp ${NET_NAME}_2
delete_network_dhcp ${NET_NAME}_3
delete_network_dhcp ${NET_NAME}_4

rm -f $ENV_FILE
