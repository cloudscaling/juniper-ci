#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

poolname="jujuimages"

source "$my_dir/functions"

juju destroy-controller -y --destroy-all-models test-cloud

delete_network juju

delete_domains

delete_volume juju-cont.qcow2 $poolname
for vol in `$virsh_cmd vol-list $poolname | awk '/juju-/{print $1}'` ; do
  echo "INFO: removing volume $vol $(date)"
  delete_volume $vol $poolname
done

delete_pool $poolname
