#!/bin/bash -eE

inner_script="${1:-deploy-manual.sh}"
if [[ $# != 0 ]] ; then
  shift
  script_params="$@"
fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/../common/functions"

if [[ "$CLEAN_BEFORE" == 'true' || "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
  cleanup_environment
  if [[ "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
    exit
  fi
fi

log_dir="$WORKSPACE/logs"
if [ -d $log_dir ] ; then
  chmod -R u+w "$log_dir"
  rm -rf "$log_dir"
fi
mkdir "$log_dir"

if [[ "$jver" == 1 ]] ; then
  echo "ERROR: only juju 2.0 and higher supports resources. Please install and use juju 2.0 or higher."
  exit 1
fi

export JOB_VERSION=R5
export SERIES="${SERIES:-xenial}"
export CONTAINER_REGISTRY=${CONTAINER_REGISTRY:-"opencontrailnightly"}
export CONTRAIL_VERSION=${CONTRAIL_VERSION:-"master-latest"}

export PASSWORD=${PASSWORD:-'password'}

echo "INFO: Date: $(date)"
echo "INFO: Starting deployment process with vars:"
env|sort

if ! juju-bootstrap ; then
  echo "ERROR: Bootstrap error. exiting..."
  exit 1
fi

# this code is only for juju 2.0
iid=`juju show-controller amazon --format yaml | awk '/instance-id/{print $2}'`
if [ -n "$iid" ] ; then
  AZ=`aws ec2 describe-instances --instance-id "$iid" --query 'Reservations[*].Instances[*].Placement.AvailabilityZone' --output text`
  vpc_id=`aws ec2 describe-instances --instance-id "$iid" --query 'Reservations[*].Instances[*].VpcId' --output text`
fi
echo "INFO: Availability zone of this deployment is $AZ, vpc is $vpc_id"
export AZ
export vpc_id

trap 'catch_errors $LINENO' ERR EXIT

function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT

  $my_dir/../save-logs.sh
  if [ -f $my_dir/save-logs.sh ] ; then
    $my_dir/save-logs.sh
  fi

  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    cleanup_environment
  fi

  exit $exit_code
}

echo "--------------------------------------------- Run deploy script: $inner_script"
$my_dir/$inner_script $script_params

# TODO: rework this...
SCP='juju scp'
SSH_CMD='juju ssh'
SSH_USER=ubuntu
master_ip=0
check_k8s_cluster

$my_dir/../save-logs.sh
if [ -f $my_dir/save-logs.sh ] ; then
  $my_dir/save-logs.sh
fi

if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  cleanup_environment
fi

trap - ERR EXIT
