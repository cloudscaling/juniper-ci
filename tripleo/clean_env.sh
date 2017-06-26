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
for vol in `virsh vol-list $poolname | awk "/overcloud-$NUM-/ {print \$1}"` ; do
  delete_volume $vol $poolname
done

rm -f "$ssh_key_dir/kp-$NUM" "$ssh_key_dir/kp-$NUM.pub"
