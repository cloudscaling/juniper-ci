#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source $my_dir/common/functions

echo "--------------------------------------------------- Save LOGS ---"

log_dir=$WORKSPACE/logs

# save status to file
juju-status > $log_dir/juju_status.log
juju-status-tabular > $log_dir/juju_status_tabular.log

truncate -s 0 $log_dir/juju_unit_statuses.log
for unit in `juju status --format oneline | awk '{print $2}' | sed 's/://g'` ; do
  if [[ -z "$unit" || "$unit" =~ "ubuntu/" || "$unit" =~ "ntp/" ]] ; then
    continue
  fi
  echo "--------------------------------- $unit statuses log" >> $log_dir/juju_unit_statuses.log
  juju show-status-log --days 1 $unit >> $log_dir/juju_unit_statuses.log
done

for mch in $(juju-get-machines) ; do
  juju-scp "$my_dir/__save-logs.sh" $mch:save_logs.sh
  juju-ssh $mch "sudo ./save_logs.sh" 2>/dev/null
  rm -f logs.tar.gz
  juju-scp $mch:logs.tar.gz logs.tar.gz
  cdir=`pwd`
  mkdir -p $log_dir/$mch
  pushd $log_dir/$mch
  tar -xf $cdir/logs.tar.gz
  popd
  rm -f logs.tar.gz
done
