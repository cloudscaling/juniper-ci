#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

rm -rf "$WORKSPACE/logs"
mkdir -p "$WORKSPACE/logs"

function save_logs() {
  $SCP "$my_dir/__save-docker-logs.sh" $SSH_DEST:save-docker-logs.sh
  $SSH "./save-docker-logs.sh"
  $my_dir/${HOST}/save-logs.sh
}

trap catch_errors ERR;
function catch_errors() {
  local exit_code=$?
  echo "Errors!" $exit_code $@

  save_logs
  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    $my_dir/${HOST}/cleanup.sh
  fi

  exit $exit_code
}

#TODO: move NUM (option server HOST) to job params
$my_dir/${HOST}/create-vm.sh
source "$my_dir/${HOST}/ssh-defs"

$SCP "$my_dir/__containers-build.sh" $SSH_DEST_BUILD:containers-build.sh
timeout -s 9 120m $SSH_BUILD "CONTRAIL_VERSION=$CONTRAIL_VERSION DOCKER_CONTRAIL_URL=$DOCKER_CONTRAIL_URL ./containers-build.sh"

# ceph.repo file is needed ONLY fow centos on aws.
$SCP "$my_dir/__ceph.repo" $SSH_DEST:ceph.repo
$SCP "$my_dir/__run-${WAY}-gate.sh" $SSH_DEST:run-${WAY}-gate.sh
timeout -s 9 120m $SSH "CONTRAIL_VERSION=$CONTRAIL_VERSION CHANGE_REF=$CHANGE_REF OPENSTACK_HELM_URL=$OPENSTACK_HELM_URL ./run-${WAY}-gate.sh $public_ip_build"

trap - ERR
save_logs
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/${HOST}/cleanup.sh
fi
