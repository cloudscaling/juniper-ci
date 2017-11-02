#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

rm -rf "$WORKSPACE/logs"
mkdir -p "$WORKSPACE/logs"

trap catch_errors ERR;

function catch_errors() {
  local exit_code=$?
  echo "Errors!" $exit_code $@

  $my_dir/aws/save-logs.sh
  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    $my_dir/aws/cleanup.sh
  fi

  exit $exit_code
}

export SSH_USER=ec2-user
# CentOS 7.4.1708 - HVM
$my_dir/aws/create-instance.sh ami-a0fddfc5 c4.4xlarge
source "$my_dir/aws/ssh-defs"

$SCP "$my_dir/__ceph.repo" $SSH_DEST:ceph.repo
$SCP "$my_dir/__run-openstack-helm-gate.sh" $SSH_DEST:run-openstack-helm-gate.sh
timeout -s 9 120m $SSH "CHANGE_REF=$CHANGE_REF ./run-openstack-helm-gate.sh"

trap - ERR
$my_dir/aws/save-logs.sh
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/aws/cleanup.sh
fi
