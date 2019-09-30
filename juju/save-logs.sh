#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source $my_dir/common/functions

echo "--------------------------------------------------- Save LOGS ---"

log_dir=$WORKSPACE/logs

# save status to file
juju-status > $log_dir/juju_status.log
juju-status-tabular > $log_dir/juju_status_tabular.log
juju export-bundle --filename $log_dir/bnundle.yaml

truncate -s 0 $log_dir/juju_unit_statuses.log
for unit in `timeout -s 9 30 juju status $juju_model_arg --format oneline | awk '{print $2}' | sed 's/://g'` ; do
  if [[ -z "$unit" || "$unit" =~ "ubuntu/" || "$unit" =~ "ntp/" ]] ; then
    continue
  fi
  echo "--------------------------------- $unit statuses log" >> $log_dir/juju_unit_statuses.log
  juju show-status-log $juju_model_arg --days 1 $unit >> $log_dir/juju_unit_statuses.log
done

for mch in $(juju-get-machines) ; do
  mkdir -p "$log_dir/$mch"
  juju-ssh $mch "df -hT" &>"$log_dir/$mch/df.log"
  juju-scp "$my_dir/__save-logs-${JOB_VERSION}.sh" $mch:save_logs.sh 2>/dev/null
  juju-ssh $mch "USE_SSL_CONTRAIL=$USE_SSL_CONTRAIL sudo -E ./save_logs.sh" 2>/dev/null
  rm -f logs.tar.gz
  juju-scp $mch:logs.tar.gz logs.tar.gz 2>/dev/null
  cdir=`pwd`
  pushd "$log_dir/$mch"
  tar -xf "$cdir/logs.tar.gz"
  for drr in upstart keystone ; do
    for fff in `find ./var/log/$drr -name "*.log"` ; do
      echo "Gzip $fff"
      gzip "$fff"
    done
  done
  popd
  rm -f logs.tar.gz
done
