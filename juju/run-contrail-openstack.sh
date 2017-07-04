#!/bin/bash -e

inner_script="${1:-deploy-manual.sh}"
if [[ $# != 0 ]] ; then
  shift
  script_params="$@"
fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/common/functions"

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

declare -A BUILDS
BUILDS=([mitaka]=22 [newton]=22)
# for builds of R4.0 from 1 to 20 version is 4.0.0.0
export CONTRAIL_VERSION="${CONTRAIL_VERSION:-4.0.1.0}"
export SERIES="${SERIES:-trusty}"
export VERSION="${VERSION:-mitaka}"
export OPENSTACK_ORIGIN="cloud:$SERIES-$VERSION"
export BUILD="${BUILD:-${BUILDS[$VERSION]}}"
export DEPLOY_AS_HA_MODE="${DEPLOY_AS_HA_MODE:-false}"
export USE_SSL_OS="${USE_SSL_OS:-false}"
export USE_SSL_CONTRAIL="${USE_SSL_CONTRAIL:-false}"
export USE_ADDITIONAL_INTERFACE="${USE_ADDITIONAL_INTERFACE:-false}"

export PASSWORD=${PASSWORD:-'password'}

echo "INFO: Date: $(date)"
echo "INFO: Starting deployment process with vars:"
env|sort

if [[ "$inner_script" == "deploy-bundle.sh" ]] ; then
  if [[ "$DEPLOY_AS_HA_MODE" == "true" ]] ; then
    echo "ERROR: bundle deployment doesn't support HA mode"
    exit 1
  fi
  if [[ "$USE_ADDITIONAL_INTERFACE" == "true" ]] ; then
    echo "ERROR: bundle deployment doesn't support deploying with additional interface"
    exit 1
  fi
fi

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
