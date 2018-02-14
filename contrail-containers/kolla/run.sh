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

# definition for baremetal deployment
export JOB_RND=$((RANDOM % 100))
export NET_ADDR=${NET_ADDR:-"10.4.$JOB_RND.0"}

function save_logs() {
  source "$my_dir/../common/${HOST}/ssh-defs"
  set +e
  $SCP "$my_dir/../__save-docker-logs.sh" $SSH_DEST:save-docker-logs.sh
  $SSH "./save-docker-logs.sh"

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

$SCP "$my_dir/../__build-containers.sh" $SSH_DEST_BUILD:build-containers.sh
$SCP -r "$WORKSPACE/contrail-container-builder" $SSH_DEST_BUILD:./
if [[ -d "$HOME/containers-cache" ]]; then
  $SCP -r "$HOME/containers-cache" $SSH_DEST_BUILD:./
fi

set -o pipefail
$SSH_BUILD "CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION LINUX_DISTR=$LINUX_DISTR CONTRAIL_INSTALL_PACKAGES_URL=$CONTRAIL_INSTALL_PACKAGES_URL timeout -s 9 180m ./build-containers.sh" |& tee $WORKSPACE/logs/build.log
set +o pipefail

$SCP "$my_dir/__run-gate.sh" $SSH_DEST:run-gate.sh
$SCP "$my_dir/__globals.yml" $SSH_DEST:globals.yml
timeout -s 9 60m $SSH "sudo CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION ./run-gate.sh $public_ip_build"

trap - ERR
save_logs
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi
