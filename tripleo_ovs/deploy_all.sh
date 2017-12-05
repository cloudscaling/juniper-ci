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

echo "INFO: creating environment $(date)"
source "$my_dir"/create_env.sh

if [[ "$DEPLOY_STAGES" == 'clean_vms' ]] ; then
  echo "INFO: DEPLOY_STAGES=$DEPLOY_STAGES"
  exit 0
fi

echo "INFO: installing undercloud $(date)"
"$my_dir"/undercloud-install.sh

if [[ "$DEPLOY_STAGES" == 'undercloud' ]] ; then
  echo "INFO: DEPLOY_STAGES=$DEPLOY_STAGES"
  exit 0
fi

echo "INFO: installing overcloud $(date)"
oc=1
ssh_env="NUM=$NUM DEPLOY=1 NETWORK_ISOLATION=$NETWORK_ISOLATION"
ssh_env+=" ENVIRONMENT_OS=$ENVIRONMENT_OS ENVIRONMENT_OS_VERSION=$ENVIRONMENT_OS_VERSION"
ssh_env+=" OPENSTACK_VERSION=$OPENSTACK_VERSION"
ssh_env+=" MGMT_IP=$MGMT_IP PROV_IP=$PROV_IP DVR=$DVR"
ssh -T $SSH_OPTS stack@$MGMT_IP "$ssh_env ./overcloud-install.sh"

if [[ "$DEPLOY_STAGES" == 'overcloud' ]] ; then
  echo "INFO: DEPLOY_STAGES=$DEPLOY_STAGES"
  exit 0
fi

echo "INFO: checking overcloud $(date)"
if [[ -n "$check_script" ]] ; then
  $check_script stack@$MGMT_IP "$SSH_OPTS"
else
  echo "WARNING: Deployment will not be checked!"
fi

trap - ERR

save_overcloud_logs

