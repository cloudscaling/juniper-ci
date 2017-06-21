#!/bin/bash -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

# su - stack
cd ~

if [[ "$(whoami)" != "stack" ]] ; then
  echo "This script must be run under the 'stack' user"
  exit 1
fi

echo "INFO: collecting overcloud logs"
source ~/stackrc

nova list
for mid in `nova list | awk '/overcloud/{print $4"+"$12}'` ; do
  mn="`echo $mid | cut -d '+' -f 1`"
  mip="`echo $mid | cut -d '=' -f 2`"
  echo "INFO: save logs from machine $mn ($mip)"
  ssh heat-admin@$mip sudo tar --ignore-failed-read -cf logs.tar /var/log/nova /var/log/cinder /var/log/glance /etc/nova /etc/cinder /etc/glance /etc/contrailctl /etc/contrail /var/log/contrail
  for dirr in 'logs' 'conf' ; do
    files=`ssh heat-admin@$mip sudo find /opt/ -name $dirr`
    ssh heat-admin@$mip sudo tar --ignore-failed-read -rf logs.tar $files
  done
  scp heat-admin@$mip:logs.tar $mn-logs.tar
done
