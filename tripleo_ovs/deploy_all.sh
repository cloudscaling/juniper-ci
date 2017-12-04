#!/bin/bash -ex

# first param is a path to script that can check it all

# first param for the script - ssh addr to undercloud
# other params - ssh opts
check_script="$1"
my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

NUM=${NUM:-0}
NETWORK_ISOLATION=${NETWORK_ISOLATION:-'single'}

trap 'catch_errors $LINENO' ERR

oc=0
function save_overcloud_logs() {
  if [[ $oc == 1 ]] ; then
    ssh -T $SSH_OPTS stack@$MGMT_IP "./save_logs.sh"
  fi
}

function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR

  # sleep some time to flush logs
  sleep 20

  save_overcloud_logs
  exit $exit_code
}

ssh_env="NUM=$NUM DEPLOY=1 NETWORK_ISOLATION=$NETWORK_ISOLATION"
ssh_env+=" BASE_ADDR=$BASE_ADDR"
ssh_env+=" ENVIRONMENT_OS=$ENVIRONMENT_OS ENVIRONMENT_OS_VERSION=$ENVIRONMENT_OS_VERSION"
ssh_env+=" OPENSTACK_VERSION=$OPENSTACK_VERSION"

echo "INFO: creating environment $(date)"
source "$my_dir"/create_env.sh

echo "INFO: installing undercloud $(date)"
"$my_dir"/undercloud-install.sh

echo "INFO: installing overcloud $(date)"
oc=1
ssh -T $SSH_OPTS stack@$MGMT_IP "$ssh_env ./overcloud-install.sh"

echo "INFO: checking overcloud $(date)"
if [[ -n "$check_script" ]] ; then
  $check_script stack@$MGMT_IP "$SSH_OPTS"
else
  echo "WARNING: Deployment will not be checked!"
fi

trap - ERR

save_overcloud_logs

