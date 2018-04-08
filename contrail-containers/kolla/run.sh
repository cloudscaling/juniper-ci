#!/bin/bash -ex

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

function save_logs() {
  source "$my_dir/../common/${HOST}/ssh-defs"
  set +e
  $SCP "$my_dir/../__save-docker-logs.sh" $SSH_DEST:save-docker-logs.sh
  $SSH "CNT_NAME_PATTERN='2-' ./save-docker-logs.sh"

  if $SSH "sudo tar -czf logs.tgz ./logs" ; then
    $SCP $SSH_DEST:logs.tgz "$WORKSPACE/logs/logs.tgz"
    pushd "$WORKSPACE/logs"
    tar -xf logs.tgz
    rm logs.tgz
    popd
  fi

  # save to workspace
  if $SSH_BUILD "sudo tar -cf logs.tar ./logs ; gzip logs.tar" ; then
    $SCP $SSH_DEST_BUILD:logs.tar.gz "$WORKSPACE/logs/build_logs.tar.gz"
    pushd "$WORKSPACE/logs"
    tar -xf build_logs.tar.gz
    rm build_logs.tar.gz
    popd
  fi
}

trap catch_errors ERR;
function catch_errors() {
  local exit_code=$?
  echo "Errors!" $exit_code $@

  save_logs
  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    $my_dir/../common/${HOST}/cleanup.sh
  fi

  exit $exit_code
}

$my_dir/../common/${HOST}/create-vm.sh
source "$my_dir/../common/${HOST}/ssh-defs"

if [[ "$REGISTRY" == 'build' || -z "$REGISTRY" ]]; then
  $SCP "$my_dir/../__build-containers.sh" $SSH_DEST_BUILD:build-containers.sh
  $SCP -r "$WORKSPACE/contrail-container-builder" $SSH_DEST_BUILD:./
  set -o pipefail
  ssh_env="CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION LINUX_DISTR=$LINUX_DISTR CONTRAIL_INSTALL_PACKAGES_URL=$CONTRAIL_INSTALL_PACKAGES_URL"
  $SSH_BUILD "$ssh_env timeout -s 9 180m ./build-containers.sh" |& tee $WORKSPACE/logs/build.log
  set +o pipefail
  CONTAINER_REGISTRY="$public_ip_build:5000"
  CONTRAIL_VERSION="ocata-$CONTRAIL_VERSION"
  REGISTRY_INSECURE=1
elif [[ "$REGISTRY" == 'opencontrailnightly' ]]; then
  CONTAINER_REGISTRY='opencontrailnightly'
  CONTRAIL_VERSION='latest'
  REGISTRY_INSECURE=0
else
  echo "ERROR: unsupported REGISTRY = $REGISTRY"
  exit 1
fi

$SCP "$my_dir/__run-gate.sh" $SSH_DEST:run-gate.sh
$SCP "$my_dir/__globals.yml" $SSH_DEST:globals.yml
$SCP "$my_dir/../common/check-functions" $SSH_DEST:check-functions
timeout -s 9 60m $SSH "sudo CONTAINER_REGISTRY=$CONTAINER_REGISTRY REGISTRY_INSECURE=$REGISTRY_INSECURE CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION ./run-gate.sh"

trap - ERR
save_logs
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi
