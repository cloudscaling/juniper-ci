#!/bin/bash -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ssh_key_dir="/home/jenkins/.ssh"

if [[ -z "$NUM" ]] ; then
  echo "Please set NUM variable to specific environment number. (export NUM=4)"
  exit 1
fi

ENVIRONMENT_OS=${ENVIRONMENT_OS:-'rhel'}

source "$my_dir/env_desc.sh"
source "$my_dir/../common/virsh/functions"

if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  # delete stack to unregister nodes
  ssh_opts="-i $ssh_key_dir/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  ssh_addr="root@${mgmt_ip}"
  ssh -T $ssh_opts $ssh_addr "sudo -u stack /home/stack/overcloud-delete.sh" || true
  # unregister undercloud
  ssh -T $ssh_opts $ssh_addr "sudo subscription-manager unregister" || true
fi

delete_network management
delete_network provisioning
delete_network external
delete_network dpdk
delete_network tsn

delete_network_dhcp $NET_NAME_MGMT
delete_network_dhcp $NET_NAME_PROV

delete_domains

vol_path=$(get_pool_path $poolname)
if [[ "$ENVIRONMENT_OS" == 'rhel' ]]; then
  rhel_unregister_system $vol_path/$undercloud_vm_volume || true
  rhel_unregister_system $vol_path/$undercloud_cert_vm_volume || true
  rhel_unregister_system $vol_path/$undercloud_freeipa_vm_volume || true
fi

delete_volume $undercloud_vm_volume $poolname
delete_volume $undercloud_cert_vm_volume $poolname
delete_volume $undercloud_freeipa_vm_volume $poolname
for vol in `virsh vol-list $poolname | awk "/overcloud-$NUM-/ {print \$1}"` ; do
  if [[ "$ENVIRONMENT_OS" == 'rhel' ]]; then
    rhel_unregister_system $vol_path/$vol || true
  fi
  delete_volume $vol $poolname
done
