#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [[ "$CLEAN_BEFORE" == 'true' || "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh || /bin/true
  if [[ "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
    exit
  fi
fi

rm -rf "$WORKSPACE/logs"
mkdir -p "$WORKSPACE/logs"

# definition for job deployment
source $my_dir/${HOST}-defs
source $my_dir/../common/functions

$my_dir/../common/${HOST}/create-vm.sh
source "$my_dir/../common/${HOST}/ssh-defs"

trap 'catch_errors $LINENO' ERR
function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"

  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    $my_dir/../common/${HOST}/cleanup.sh
  fi

  exit $exit_code
}

$SCP "$WORKSPACE/cloudrc" $SSH_USER@$master_ip:cloudrc
$SCP "$my_dir/__run-gate.sh" $SSH_USER@$master_ip:run-gate.sh
run_env+=" JOB_RND=$JOB_RND NET_BASE_PREFIX=$NET_BASE_PREFIX"
run_env+=" OPENSTACK_VERSION=$OPENSTACK_VERSION LINUX_DISTR=$LINUX_DISTR"
run_env+=" AGENT_MODE=$AGENT_MODE"
timeout -s 9 120m $SSH_CMD $SSH_USER@$master_ip "$run_env ./run-gate.sh"

trap - ERR
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi
