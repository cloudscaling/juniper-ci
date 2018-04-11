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
      $SSH_CMD ${SSH_USER}@${dest} "./save-docker-logs.sh"
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

if [[ "$REGISTRY" == 'build' ]]; then
  $SCP "$my_dir/../__build-containers.sh" $SSH_USER@$build_ip:build-containers.sh
  $SCP -r "$WORKSPACE/contrail-container-builder" $SSH_USER@$build_ip:./
  set -o pipefail
  ssh_env="CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION"
  ssh_env+=" LINUX_DISTR=$LINUX_DISTR CONTRAIL_INSTALL_PACKAGES_URL=$CONTRAIL_INSTALL_PACKAGES_URL"
  $SSH_CMD $SSH_USER@$build_ip "$ssh_env timeout -s 9 180m ./build-containers.sh" |& tee $WORKSPACE/logs/build.log
  set +o pipefail
  CONTAINER_REGISTRY="$build_ip:5000"
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

# clone repos to all nodes
for ip in $nodes_ips ; do
    cat <<EOM | $SSH_CMD $SSH_USER@$ip
sudo mkdir -p /opt
sudo chown $USER /opt
cd /opt
# Download openstack-helm code
git clone https://github.com/Juniper/openstack-helm.git
pushd openstack-helm
#git fetch https://review.opencontrail.org/Juniper/openstack-helm refs/changes/52/40952/4 && git checkout FETCH_HEAD
#git pull --rebase origin master
popd
# Download openstack-helm-infra code
git clone https://github.com/Juniper/openstack-helm-infra.git
# Download contrail-helm-deployer code
git clone https://github.com/Juniper/contrail-helm-deployer.git
pushd contrail-helm-deployer
#git fetch https://review.opencontrail.org/Juniper/contrail-helm-deployer refs/changes/66/41266/4 && git checkout FETCH_HEAD
#git pull --rebase origin master
popd
EOM
done

$SCP "$WORKSPACE/cloudrc" $SSH_USER@$master_ip:cloudrc
$SCP "$my_dir/__run-gate.sh" $SSH_USER@$master_ip:run-gate.sh
ssh_env="CONTAINER_REGISTRY=$CONTAINER_REGISTRY REGISTRY_INSECURE=$REGISTRY_INSECURE"
ssh_env+=" CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION LINUX_DISTR=$LINUX_DISTR"
ssh_env+=" AGENT_MODE=$AGENT_MODE"
timeout -s 9 120m $SSH_CMD $SSH_USER@$master_ip "$ssh_env ./run-gate.sh"

trap - ERR
save_logs
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi
