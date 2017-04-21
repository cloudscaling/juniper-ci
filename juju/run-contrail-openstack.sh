#!/bin/bash -e

inner_script="${1:-deploy-manual.sh}"
shift
script_params="$@"

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

log_dir=$WORKSPACE/logs
rm -rf $log_dir
mkdir $log_dir

source $my_dir/common/functions

if [[ "$jver" == 1 ]] ; then
  echo "ERROR: only juju 2.0 and higher supports resources. Please install and use juju 2.0 or higher."
  exit 1
fi

SERIES=${SERIES:-trusty}
export SERIES
VERSION=${VERSION:-"cloud:$SERIES-mitaka"}
export VERSION

if ! juju-bootstrap ; then
  echo "Bootstrap error. exiting..."
  exit 1
fi
AZ=`juju-status | grep -Po " availability-zone=.*[ $]*" | cut -d '=' -f 2`
echo "INFO: Availability zone of this deployment is $AZ"
export AZ

trap 'catch_errors $LINENO' ERR EXIT

function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT

  $my_dir/save-logs.sh
  if [ -f $my_dir/contrail/save-logs.sh ] ; then
    $my_dir/contrail/save-logs.sh
  fi

  if [[ $CLEAN_ENV != 'false' ]] ; then
    cleanup_environment
  fi

  exit $exit_code
}

echo "--------------------------------------------- Run deploy script: $inner_script"
$my_dir/contrail/$inner_script $script_params

create_stackrc
$my_dir/contrail/check-openstack.sh

#if [[ "$RUN_TEMPEST" == 'true' ]] ; then
#  $my_dir/contrail/run-tempest.sh
#fi

$my_dir/save-logs.sh
if [ -f $my_dir/contrail/save-logs.sh ] ; then
  $my_dir/contrail/save-logs.sh
fi

if [[ $CLEAN_ENV != 'false' ]] ; then
  cleanup_environment
fi

trap - ERR EXIT
