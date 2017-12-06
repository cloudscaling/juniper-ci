#!/bin/bash -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [[ -z "$NUM" ]] ; then
  echo "Please set NUM variable to specific environment number. (export NUM=4)"
  exit 1
fi
poolname="rdimages"

source "$my_dir/../common/virsh/functions"

delete_network_dhcp e${NUM}-prov
delete_network_dhcp e${NUM}-mgmt

delete_domains "e${NUM}-"

vol_path=$(get_pool_path $poolname)

for vol in `virsh vol-list $poolname | awk "/e$NUM-/ {print \$1}"` ; do
  delete_volume $vol $poolname
done
