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
  # save common docker logs
  for dest in ${SSH_DEST_WORKERS[@]} ; do
    # TODO: when repo be splitted to containers & build here will be containers repo only,
    # then build repo should be added to be copied below
    $SCP "$my_dir/../__save-docker-logs.sh" ${dest}:save-docker-logs.sh
    ssh -i $ssh_key_file $SSH_OPTS ${dest} "./save-docker-logs.sh"
  done

  # save env host specific logs
  # (should save into ~/logs folder on the SSH host)
  $my_dir/../common/${HOST}/save-logs.sh

  # save to workspace
  for dest in ${SSH_DEST_WORKERS[@]} ; do
    if ssh -i $ssh_key_file $SSH_OPTS ${dest} "sudo tar -cf logs.tar ./logs ; gzip logs.tar" ; then
      local lname=$(echo $dest | cut -d '@' -f 2)
      mkdir -p "$WORKSPACE/logs/$lname"
      $SCP ${dest}:logs.tar.gz "$WORKSPACE/logs/${lname}/logs.tar.gz"
      pushd "$WORKSPACE/logs/$lname"
      tar -xf logs.tar.gz
      rm logs.tar.gz
      popd
    fi
  done

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

for dest in ${SSH_DEST_WORKERS[@]} ; do
  # TODO: when repo be splitted to containers & build here will be containers repo only,
  # then build repo should be added to be copied below
  $SCP -r "$WORKSPACE/contrail-container-builder" ${dest}:./
done
$my_dir/setup-nodes.sh

$SCP "$my_dir/../__build-${BUILD_TARGET}.sh" $SSH_DEST_BUILD:build-${BUILD_TARGET}.sh
$SCP "$my_dir/../__functions" $SSH_DEST_BUILD:functions
$SCP -r "$WORKSPACE/contrail-build-poc" $SSH_DEST_BUILD:./

set -o pipefail
$SSH_BUILD "CONTRAIL_VERSION=$CONTRAIL_VERSION timeout -s 9 180m ./build-${BUILD_TARGET}.sh" |& tee $WORKSPACE/logs/build.log
set +o pipefail

$SCP "$my_dir/__run-gate.sh" $SSH_DEST:run-gate.sh
timeout -s 9 60m $SSH "CONTRAIL_VERSION=$CONTRAIL_VERSION ./run-gate.sh $public_ip_build"

trap - ERR
save_logs
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi
