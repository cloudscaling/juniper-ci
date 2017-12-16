#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/functions"

if juju show-controller $juju_controller_name ; then
  juju remove-machine 0 --force || /bin/true
  juju remove-machine 1 --force || /bin/true
  juju remove-machine 2 --force || /bin/true
  juju remove-machine 3 --force || /bin/true
  juju remove-machine 4 --force || /bin/true
  juju remove-machine 5 --force || /bin/true
  juju destroy-controller -y --destroy-all-models $juju_controller_name || /bin/true
fi

delete_network $nname
delete_network $nname_ext

delete_domains

delete_volume ${job_prefix}-cont.qcow2 $poolname
for vol in `$virsh_cmd vol-list $poolname | grep "${job_prefix}" | awk '{print $1}'` ; do
  echo "INFO: removing volume $vol $(date)"
  delete_volume $vol $poolname
done

delete_pool $poolname
