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
    timeout -s 9 20s $SCP "$my_dir/../__save-docker-logs.sh" ${SSH_USER}@${dest}:save-docker-logs.sh
    if [[ $? == 0 ]] ; then
      $SSH_CMD ${SSH_USER}@${dest} "CNT_NAME_PATTERN='2-' ./save-docker-logs.sh"
    fi
  done

  # save to workspace
  for dest in $nodes_ips ; do
    if timeout -s 9 30s $SSH_CMD ${SSH_USER}@${dest} "sudo tar -cf logs.tar ./logs ; gzip logs.tar" ; then
      local lname=$(echo $dest | cut -d '@' -f 2)
      local ldir="$WORKSPACE/logs/$lname"
      mkdir -p "$ldir"
      timeout -s 9 10s $SCP $SSH_USER@${dest}:logs.tar.gz "$ldir/logs.tar.gz"
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

run_env=''
if [[ "$REGISTRY" == 'build' ]]; then
  $SCP "$my_dir/../__build-containers.sh" $SSH_USER@$build_ip:build-containers.sh
  $SCP -r "$WORKSPACE/contrail-container-builder" $SSH_USER@$build_ip:./
  set -o pipefail
  ssh_env="CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION"
  ssh_env+=" LINUX_DISTR=$LINUX_DISTR CONTRAIL_INSTALL_PACKAGES_URL=$CONTRAIL_INSTALL_PACKAGES_URL"
  $SSH_CMD $SSH_USER@$build_ip "$ssh_env timeout -s 9 180m ./build-containers.sh" |& tee $WORKSPACE/logs/build.log
  set +o pipefail
  run_env="CONTAINER_REGISTRY=$build_ip:5000 CONTRAIL_VERSION=ocata-$CONTRAIL_VERSION REGISTRY_INSECURE=1"
elif [[ "$REGISTRY" == 'opencontrailnightly' ]]; then
  run_env="CONTAINER_REGISTRY=opencontrailnightly CONTRAIL_VERSION=latest REGISTRY_INSECURE=0"
else
  echo "ERROR: unsupported REGISTRY = $REGISTRY"
  exit 1
fi

$SCP "$my_dir/__run-gate.sh" $SSH_USER@$master_ip:run-gate.sh
$SCP "$my_dir/__globals.yml" $SSH_USER@$master_ip:globals.yml
$SCP "$my_dir/../common/check-functions" $SSH_USER@$master_ip:check-functions
run_env+=" SSL_ENABLE=$SSL_ENABLE  OPENSTACK_VERSION=$OPENSTACK_VERSION"
timeout -s 9 60m $SSH_CMD $SSH_USER@$master_ip "sudo $run_env ./run-gate.sh"

trap - ERR
save_logs
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi
