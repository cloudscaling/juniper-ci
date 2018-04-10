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
  # save common docker logs
  for dest in $nodes_ips ; do
    # TODO: when repo be splitted to containers & build here will be containers repo only,
    # then build repo should be added to be copied below
    $SCP "$my_dir/../__save-docker-logs.sh" $SSH_USER@${dest}:save-docker-logs.sh
    $SSH_CMD $SSH_USER@${dest} "./save-docker-logs.sh"
  done

  # save env host specific logs
  # (should save into ~/logs folder on the SSH host)
  $my_dir/../common/${HOST}/save-logs.sh

  # save to workspace
  for dest in $nodes_ips ; do
    if $SSH_CMD $SSH_USER@${dest} "sudo tar -cf logs.tar ./logs ; gzip logs.tar" ; then
      local ldir="$WORKSPACE/logs/$dest"
      mkdir -p "$ldir"
      $SCP $SSH_USER@${dest}:logs.tar.gz "$ldir/logs.tar.gz"
      pushd "$ldir"
      tar -xf logs.tar.gz
      rm logs.tar.gz
      popd
    fi
  done
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

for dest in $nodes_ips ; do
  $SCP -r "$WORKSPACE/contrail-container-builder" $SSH_USER@${dest}:./
done
$my_dir/setup-nodes.sh


if [[ "$REGISTRY" == 'build' ]]; then
  $SCP -r "$WORKSPACE/contrail-container-builder" $SSH_USER@$build_ip:./
  $SCP "$my_dir/../__build-containers.sh" ${SSH_USER}@$build_ip:build-containers.sh
  set -o pipefail
  ssh_env="CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION LINUX_DISTR=$LINUX_DISTR"
  ssh_env+=" CONTRAIL_INSTALL_PACKAGES_URL=$CONTRAIL_INSTALL_PACKAGES_URL"
  $SSH_CMD ${SSH_USER}@$build_ip "$ssh_env timeout -s 9 180m ./build-containers.sh" |& tee $WORKSPACE/logs/build.log
  set +o pipefail
  CONTAINER_REGISTRY="$build_ip:5000"
else
  echo "ERROR: unsupported REGISTRY = $REGISTRY"
  exit 1
fi

$SCP "$my_dir/__run-gate.sh" ${SSH_USER}@$master_ip:run-gate.sh
timeout -s 9 60m $SSH_CMD ${SSH_USER}@$master_ip "CONTRAIL_VERSION=$CONTRAIL_VERSION CONTRAIL_REGISTRY=$CONTAINER_REGISTRY LINUX_DISTR=$LINUX_DISTR AGENT_MODE=$AGENT_MODE ./run-gate.sh"

trap - ERR
save_logs
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi
