#!/bin/bash -e

inner_script="${1:-deploy-manual.sh}"
if [[ $# != 0 ]] ; then
  shift
  script_params="$@"
fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/functions"

export log_dir="$WORKSPACE/logs"
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
BUILDS=([mitaka]=33 [newton]=33 [ocata]=33)
# for builds of R4.0 from 1 to 20 version is 4.0.0.0
# for builds of R4.0 from 21 to 32 version is 4.0.1.0
export CONTRAIL_VERSION="${CONTRAIL_VERSION:-4.0.2.0}"
export SERIES="${SERIES:-xenial}"
export VERSION="${VERSION:-newton}"
export OPENSTACK_ORIGIN="cloud:$SERIES-$VERSION"
export BUILD="${BUILD:-${BUILDS[$VERSION]}}"
export DEPLOY_MODE="${DEPLOY_MODE:-two}"
export USE_SSL_OS="${USE_SSL_OS:-false}"
export USE_SSL_CONTRAIL="false"
export USE_ADDITIONAL_INTERFACE="${USE_ADDITIONAL_INTERFACE:-false}"
export USE_DPDK="${USE_DPDK:-false}"
export AAA_MODE=${AAA_MODE:-rbac}

export PASSWORD=${PASSWORD:-'password'}

if [[ "$SERIES" == 'xenial' ]]; then
  export IF1='ens3'
  export IF2='ens4'
else
  export IF1='eth0'
  export IF2='eth1'
fi

# check if environment is present
if $virsh_cmd list --all | grep -q "juju-cont" ; then
  echo 'ERROR: environment present. please clean up first'
  $virsh_cmd list --all | grep "juju-"
  exit 1
fi

trap 'catch_errors $LINENO' ERR EXIT

function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT

  juju status || /bin/true
  $my_dir/../save-logs.sh

  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    echo "INFO: cleaning environment $(date)"
    "$my_dir"/clean_env.sh
  fi

  exit $exit_code
}

echo "INFO: Date: $(date)"
echo "INFO: Starting deployment process with vars:"
env|sort

echo "INFO: creating environment $(date)"
"$my_dir"/create_env.sh
juju status

"$my_dir"/deploy_manual.sh

#check it
$my_dir/../contrail/check-openstack.sh

$my_dir/../save-logs.sh

trap - ERR EXIT

if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  echo "INFO: cleaning environment $(date)"
  "$my_dir"/clean_env.sh
fi
