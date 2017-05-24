#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

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

key_file="/home/stack/.ssh/authorized_keys"
if [[ ! -f ${key_file} ]] ; then
  key_file="/home/stack/.ssh/authorized_keys2"
fi
if [[ ! -f ${key_file} ]] ; then
  grep -v "my${NUM}domain" ${key_file} > ${key_file}_f
  chown stack:stack ${key_file}_f
  chmod 600 ${key_file}authorized_keys_f
  mv ${key_file}_f ${key_file}
fi

rm -f "$my_dir/kp-$NUM" "$my_dir/kp-$NUM.pub"
