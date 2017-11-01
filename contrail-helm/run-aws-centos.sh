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

# dcos-centos7-201710*
$my_dir/aws/create-instance.sh ami-02b69a67 c4.4xlarge
source "$my_dir/aws/ssh-defs"

$SCP "$my_dir/__run-openstack-helm-gate.sh" $SSH_DEST:run-openstack-helm-gate.sh
$SSH "$HOME/run-openstack-helm-gate.sh"

trap - ERR
$my_dir/aws/save-logs.sh
$my_dir/aws/cleanup.sh


