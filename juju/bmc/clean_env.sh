#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

poolname="jujuimages"

source "$my_dir/functions"

delete_network juju

delete_domains

delete_volume juju-cont.qcow2 $poolname
for vol in `virsh vol-list $poolname | awk "/juju-/ {print \$1}"` ; do
  delete_volume $vol $poolname
done
