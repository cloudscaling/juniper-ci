#!/bin/bash -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ssh_key_dir="/home/jenkins"

if [[ -z "$NUM" ]] ; then
  echo "Please set NUM variable to specific environment number. (export NUM=4)"
  exit 1
fi
if [[ -z "$ENVIRONMENT_OS" ]] ; then
  echo "Please set ENVIRONMENT_OS variable to specific environment number. (export ENVIRONMENT_OS=rhel)"
  exit 1
fi

poolname="rdimages"

source "$my_dir/../common/virsh/functions"

if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  # delete stack to unregister nodes
  BASE_ADDR=${BASE_ADDR:-172}
  ((env_addr=BASE_ADDR+NUM*10))
  ip_addr="192.168.${env_addr}.2"
  ssh_opts="-i $ssh_key_dir/kp-$NUM -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  ssh_addr="root@${ip_addr}"
  ssh -T $ssh_opts $ssh_addr "sudo -u stack /home/stack/overcloud-delete.sh" || true
  # unregister undercloud
  ssh -T $ssh_opts $ssh_addr "sudo subscription-manager unregister" || true
fi

delete_network management
delete_network provisioning
delete_network external
delete_network dpdk
delete_network tsn

delete_domains

vol_path=$(get_pool_path $poolname)
if [[ "$ENVIRONMENT_OS" == 'rhel' ]]; then
  rhel_unregister_system $vol_path/undercloud-$NUM.qcow2 || true
  rhel_unregister_system $vol_path/undercloud-$NUM-cert-test.qcow2 || true
fi

delete_volume undercloud-$NUM.qcow2 $poolname
delete_volume undercloud-$NUM-cert-test.qcow2 $poolname
for vol in `virsh vol-list $poolname | awk "/overcloud-$NUM-/ {print \$1}"` ; do
  if [[ "$ENVIRONMENT_OS" == 'rhel' ]]; then
    rhel_unregister_system $vol_path/$vol || true
  fi
  delete_volume $vol $poolname
done

rm -f "$ssh_key_dir/kp-$NUM" "$ssh_key_dir/kp-$NUM.pub"
