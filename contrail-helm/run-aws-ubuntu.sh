#!/bin/bash -ex

export CONTRAIL_VERSION=4.0.2.0-35

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
$my_dir/aws/create-instances.sh ami-0a00ce72
source "$my_dir/aws/ssh-defs"

$SCP "$my_dir/__containers-build-ubuntu.sh" $SSH_DEST_BUILD:containers-build-ubuntu.sh
timeout -s 9 120m $SSH_BUILD "CONTRAIL_VERSION=$CONTRAIL_VERSION DOCKER_CONTRAIL_URL=$DOCKER_CONTRAIL_URL ./containers-build-ubuntu.sh"

$SCP "$my_dir/__run-openstack-helm-gate.sh" $SSH_DEST:run-openstack-helm-gate.sh
timeout -s 9 120m $SSH "CONTRAIL_VERSION=$CONTRAIL_VERSION CHANGE_REF=$CHANGE_REF OPENSTACK_HELM_URL=$OPENSTACK_HELM_URL ./run-openstack-helm-gate.sh $public_ip_build"

$SCP "$my_dir/__save-docker-logs.sh" $SSH_DEST:save-docker-logs.sh
$SSH "./save-docker-logs.sh"

trap - ERR
$my_dir/aws/save-logs.sh
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/aws/cleanup.sh
fi
