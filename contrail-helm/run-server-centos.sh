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

$SCP "$my_dir/__containers-build-centos.sh" $SSH_DEST_BUILD:containers-build-centos.sh
timeout -s 9 120m $SSH_BUILD "DOCKER_CONTRAIL_URL=$DOCKER_CONTRAIL_URL ./containers-build-centos.sh"

# $SCP "$my_dir/__ceph.repo" $SSH_DEST:ceph.repo
# $SCP "$my_dir/__run-openstack-helm-gate.sh" $SSH_DEST:run-openstack-helm-gate.sh
# timeout -s 9 120m $SSH "CHANGE_REF=$CHANGE_REF OPENSTACK_HELM_URL=$OPENSTACK_HELM_URL ./run-openstack-helm-gate.sh $public_ip_build"

trap - ERR
$my_dir/server/save-logs.sh
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/server/cleanup.sh
fi
