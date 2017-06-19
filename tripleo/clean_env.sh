#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ssh_key_dir="/home/jenkins"

if [[ -z "$NUM" ]] ; then
  echo "Please set NUM variable to specific environment number. (export NUM=4)"
  exit 1
fi
poolname="rdimages"

source "$my_dir/functions"

delete_network management
delete_network provisioning
delete_network external

delete_domains

delete_volume undercloud-$NUM.qcow2 $poolname
# TODO: calculate real count of existing volumes
for (( i=1; i<=10; i++ )) ; do
  delete_volume overcloud-$NUM-cont-$i.qcow2 $poolname
  delete_volume overcloud-$NUM-comp-$i.qcow2 $poolname
  delete_volume overcloud-$NUM-comp-$i-store.qcow2 $poolname
  delete_volume overcloud-$NUM-stor-$i.qcow2 $poolname
  delete_volume overcloud-$NUM-stor-$i-store.qcow2 $poolname
  delete_volume overcloud-$NUM-ctrlcont-$i.qcow2 $poolname
done

rm -f "$ssh_key_dir/kp-$NUM" "$ssh_key_dir/kp-$NUM.pub"
