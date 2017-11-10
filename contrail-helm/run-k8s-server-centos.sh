#!/bin/bash -ex

export CONTRAIL_VERSION=${CONTRAIL_VERSION:-'4.0.2.0-35'}

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

rm -rf "$WORKSPACE/logs"
mkdir -p "$WORKSPACE/logs"

trap catch_errors ERR;

function catch_errors() {
  local exit_code=$?
  echo "Errors!" $exit_code $@

  $my_dir/server/save-logs.sh
  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    $my_dir/server/cleanup.sh
  fi

  exit $exit_code
}

#TODO: move NUM to job params
$my_dir/server/create-vm.sh centos ocata

source "$my_dir/server/ssh-defs"

$SCP "$my_dir/__containers-build-centos.sh" $SSH_DEST_BUILD:containers-build-centos.sh
timeout -s 9 120m $SSH_BUILD "CONTRAIL_VERSION=$CONTRAIL_VERSION DOCKER_CONTRAIL_URL=$DOCKER_CONTRAIL_URL ./containers-build-centos.sh"

$SCP "$my_dir/__run-k8s-gate.sh" $SSH_DEST:run-k8s-gate.sh
timeout -s 9 120m $SSH "CONTRAIL_VERSION=$CONTRAIL_VERSION CHANGE_REF=$CHANGE_REF ./run-k8s-gate.sh"

trap - ERR
$my_dir/server/save-logs.sh
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/server/cleanup.sh
fi
