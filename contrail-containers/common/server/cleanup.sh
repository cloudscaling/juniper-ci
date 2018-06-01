#!/bin/bash -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

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

# assume that POOL_NAME is not dependent from JOB_RND
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

# source default values
source "$my_dir/definitions"
# check that current JOB_RND equals to existed in the system
existed_jobs=`virsh net-list --all | grep $prefix | awk '{print $1}' | cut -d '-' -f 4 | sort | uniq`
echo "INFO: Current job: $JOB_RND, Existed jobs to cleanup: $existed_jobs"

for job in $existed_jobs ; do
  # override JOB_RND and re-source definitions
  export JOB_RND="$job"
  source "$my_dir/definitions"

  for i in `virsh list --all | grep $VM_NAME | awk '{print $2}'` ; do
    delete_node $i
  done
  delete_network_dhcp $NET_NAME
  delete_network_dhcp ${NET_NAME}_1
  delete_network_dhcp ${NET_NAME}_2
  delete_network_dhcp ${NET_NAME}_3
  delete_network_dhcp ${NET_NAME}_4
done
