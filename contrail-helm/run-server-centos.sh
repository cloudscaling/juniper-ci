#!/bin/bash -ex

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

$SCP "$my_dir/__ceph.repo" $SSH_DEST:ceph.repo
$SCP "$my_dir/__run-openstack-helm-gate.sh" $SSH_DEST:run-openstack-helm-gate.sh

error=0
timeout -s 9 120m $SSH "CHANGE_REF=$CHANGE_REF ./run-openstack-helm-gate.sh" || error=1

$SCP "$my_dir/__containers-build-centos.sh" $SSH_DEST:containers-build-centos.sh
$SSH "./containers-build-centos.sh"

trap - ERR
$my_dir/server/save-logs.sh
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/server/cleanup.sh
fi

exit $error
