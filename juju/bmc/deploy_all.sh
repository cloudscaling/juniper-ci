#!/bin/bash -e

inner_script="${1:-deploy-manual.sh}"
if [[ $# != 0 ]] ; then
  shift
  script_params="$@"
fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

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

trap 'catch_errors $LINENO' ERR EXIT

function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT

#  $my_dir/save-logs.sh
#  if [ -f $my_dir/contrail/save-logs.sh ] ; then
#    $my_dir/contrail/save-logs.sh
#  fi

  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    echo "INFO: cleaning environment $(date)"
    sudo "$my_dir"/clean_env.sh
  fi

  exit $exit_code
}

echo "INFO: Date: $(date)"
echo "INFO: Starting deployment process with vars:"
env|sort





echo "INFO: creating environment $(date)"
sudo "$my_dir"/create_env.sh
echo "INFO: installing juju controller $(date)"

#deploy bundle/manual

juju status


#check it
#$my_dir/../contrail/check-openstack.sh


#$my_dir/save-logs.sh
#if [ -f $my_dir/contrail/save-logs.sh ] ; then
#  $my_dir/contrail/save-logs.sh
#fi

trap - ERR EXIT

if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  echo "INFO: cleaning environment $(date)"
  sudo "$my_dir"/clean_env.sh
fi
