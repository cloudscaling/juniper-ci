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

$SCP "$my_dir/../__build-${BUILD_TARGET}.sh" $SSH_DEST_BUILD:build-${BUILD_TARGET}.sh
$SCP "$my_dir/../__functions" $SSH_DEST_BUILD:functions
$SCP -r "$WORKSPACE/contrail-container-builder" $SSH_DEST_BUILD:./
$SCP -r "$WORKSPACE/contrail-build-poc" $SSH_DEST_BUILD:./
if [[ "$BUILD_TARGET" == 'containers' ]] ; then
  # helm's gating is not very fast. it takes more than 25 minutes. we can build containers in background.
  echo "INFO: ($(date)) run build in background then wait some time and run helm gating"
  $SSH_BUILD "CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION timeout -s 9 60m ./build-${BUILD_TARGET}.sh" &>$WORKSPACE/logs/build.log &
  # wait some time while it prepares vrouter.ko on www that is needed for gate in the beginning
  timeout -s 9 300s tail -f $WORKSPACE/logs/build.log || /bin/true
  echo "INFO: ($(date)) continuing with helm deployment"
else
  # but in case full build time is not so critical...
  set -o pipefail
  $SSH_BUILD "CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION timeout -s 9 180m ./build-${BUILD_TARGET}.sh" |& tee $WORKSPACE/logs/build.log
  set +o pipefail
fi

# ceph.repo file is needed ONLY fow centos on aws.
$SCP "$my_dir/__ceph.repo" $SSH_DEST:ceph.repo
$SCP "$my_dir/__run-gate.sh" $SSH_DEST:run-gate.sh
timeout -s 9 60m $SSH "CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION ./run-gate.sh $public_ip_build"

trap - ERR
save_logs
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi
