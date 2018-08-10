#!/bin/bash -e

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
source $my_dir/../common/functions

$my_dir/../common/${HOST}/create-vm.sh
source "$my_dir/../common/${HOST}/ssh-defs"

trap 'catch_errors $LINENO' ERR
function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"

  save_logs '2,3'
  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    $my_dir/../common/${HOST}/cleanup.sh
  fi

  exit $exit_code
}

run_env=''
if [[ "$REGISTRY" == 'build' ]]; then
  $SCP "$my_dir/../__build-containers.sh" $SSH_USER@$build_ip:build-containers.sh
  $SCP -r "$WORKSPACE/contrail-container-builder" $SSH_USER@$build_ip:./
  set -o pipefail
  ssh_env="CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION"
  ssh_env+=" LINUX_DISTR=$LINUX_DISTR CONTRAIL_INSTALL_PACKAGES_URL=$CONTRAIL_INSTALL_PACKAGES_URL"
  $SSH_CMD $SSH_USER@$build_ip "$ssh_env timeout -s 9 180m ./build-containers.sh" |& tee $WORKSPACE/logs/build.log
  set +o pipefail
  run_env="CONTAINER_REGISTRY=$build_ip:5000 CONTRAIL_VERSION=$OPENSTACK_VERSION-$CONTRAIL_VERSION REGISTRY_INSECURE=1"
elif [[ "$REGISTRY" == 'opencontrailnightly' ]]; then
  run_env="CONTAINER_REGISTRY=opencontrailnightly CONTRAIL_VERSION=latest REGISTRY_INSECURE=0"
else
  echo "ERROR: unsupported REGISTRY = $REGISTRY"
  exit 1
fi

# clone repos to all nodes
for ip in $nodes_ips ; do
  echo "INFO: some debug info about node $i"
  $SSH_CMD $SSH_USER@$ip "hostname -i ; cat /etc/hosts"

  echo "INFO: clone helm repos to node $ip"
  $SSH_CMD $SSH_USER@$ip "sudo mkdir -p /opt && sudo chown $SSH_USER /opt"
  for repo in 'openstack-helm' 'openstack-helm-infra' 'contrail-helm-deployer' ; do
    $SSH_CMD $SSH_USER@$ip "git clone https://github.com/Juniper/${repo}.git /opt/$repo"
    if echo "$PATCHSET_LIST" | grep -q "/${repo} " ; then
      patchset=`echo "$PATCHSET_LIST" | grep "/${repo} "`
      $SSH_CMD $SSH_USER@$ip "cd /opt/$repo ; $patchset ; git pull --rebase origin master"
    fi
  done
done

$SCP "$WORKSPACE/cloudrc" $SSH_USER@$master_ip:cloudrc
$SCP "$my_dir/../common/check-functions" $SSH_USER@$master_ip:check-functions
$SCP "$my_dir/__run-gate.sh" $SSH_USER@$master_ip:run-gate.sh
run_env+=" JOB_RND=$JOB_RND NET_BASE_PREFIX=$NET_BASE_PREFIX"
run_env+=" OPENSTACK_VERSION=$OPENSTACK_VERSION LINUX_DISTR=$LINUX_DISTR"
run_env+=" AGENT_MODE=$AGENT_MODE SSL_ENABLE=$SSL_ENABLE"
timeout -s 9 120m $SSH_CMD $SSH_USER@$master_ip "$run_env ./run-gate.sh"

trap - ERR
save_logs '2,3'
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi
