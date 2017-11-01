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
  $my_dir/aws/cleanup.sh

  exit $exit_code
}

# centos-7.4-plain-x86_64-170922_19-disk1-6f5e98a1-bc66-4b6a-a37d-efb4b2472f8a-ami-d6498cac.4
$my_dir/aws/create-instance.sh ami-d6af6dae
source "$my_dir/aws/ssh-defs"

$SCP "$my_dir/__run-openstack-helm-gate.sh" $SSH_DEST:run-openstack-helm-gate.sh
$SSH "$HOME/run-openstack-helm-gate.sh"

trap - ERR
$my_dir/aws/save-logs.sh
$my_dir/aws/cleanup.sh


