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

export AWS_FLAGS="--region us-west-2"
export SSH_USER=ubuntu
# ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-201710
# us-east-2 : ami-336b4456
# us-west-2 : ami-0a00ce72
$my_dir/aws/create-instance.sh ami-0a00ce72 c4.4xlarge
source "$my_dir/aws/ssh-defs"

$SCP "$my_dir/__run-openstack-helm-gate.sh" $SSH_DEST:run-openstack-helm-gate.sh
$SCP "$my_dir/__containers-build-ubuntu.sh" $SSH_DEST:containers-build-ubuntu.sh
timeout -s 9 120m $SSH "CHANGE_REF=$CHANGE_REF DOCKER_CONTRAIL_URL=$DOCKER_CONTRAIL_URL OPENSTACK_HELM_URL=$OPENSTACK_HELM_URL ./run-openstack-helm-gate.sh"

trap - ERR
$my_dir/aws/save-logs.sh
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/aws/cleanup.sh
fi
