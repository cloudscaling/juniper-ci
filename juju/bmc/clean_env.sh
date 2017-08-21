#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

poolname="jujuimages"

source "$my_dir/functions"

juju remove-machine 0 --force || /bin/true
juju remove-machine 1 --force || /bin/true
juju remove-machine 2 --force || /bin/true
juju remove-machine 3 --force || /bin/true
juju remove-machine 4 --force || /bin/true
juju remove-machine 5 --force || /bin/true
juju destroy-controller -y --destroy-all-models test-cloud || /bin/true

rm -rf $HOME/.local/share/juju

delete_network $nname
delete_network $nname_vm

delete_domains

delete_volume juju-cont.qcow2 $poolname
for vol in `$virsh_cmd vol-list $poolname | awk '/juju-/{print $1}'` ; do
  echo "INFO: removing volume $vol $(date)"
  delete_volume $vol $poolname
done

delete_pool $poolname
