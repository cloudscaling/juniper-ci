#!/bin/bash -eEa

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
source $my_dir/../common/check-functions

$my_dir/../common/${HOST}/create-vm.sh
source "$my_dir/../common/${HOST}/setup-defs"

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
if [[ "$CONTAINER_REGISTRY" == 'build' || "$CONTAINER_REGISTRY" == 'fullbuild' ]]; then
  source "$my_dir/../common/${HOST}/definitions"
  build_containers
  run_env="CONTAINER_REGISTRY=$build_ip:5000 CONTRAIL_VERSION=$OPENSTACK_VERSION-$CONTRAIL_VERSION REGISTRY_INSECURE=1"
else
  run_env="CONTAINER_REGISTRY=$CONTAINER_REGISTRY CONTRAIL_VERSION=$CONTRAIL_VERSION REGISTRY_INSECURE=0"
fi

# clone repos to all nodes
for ip in $nodes_ips ; do
  echo "INFO: some debug info about node $i"
  $SSH_CMD $SSH_USER@$ip "hostname -i ; cat /etc/hosts"

  echo "INFO: clone helm repos to node $ip"
  $SSH_CMD $SSH_USER@$ip "sudo mkdir -p /opt && sudo chown $SSH_USER /opt"
  for repo in 'openstack-helm' 'openstack-helm-infra' 'contrail-helm-deployer' ; do
    org='Juniper'
    #if [[ "$repo" == 'contrail-helm-deployer' ]]; then org='progmaticlab' ; fi
    $SSH_CMD $SSH_USER@$ip "git clone https://github.com/$org/${repo}.git /opt/$repo"
    if echo "$PATCHSET_LIST" | grep -q "/${repo} " ; then
      patchset=`echo "$PATCHSET_LIST" | grep "/${repo} "`
      $SSH_CMD $SSH_USER@$ip "cd /opt/$repo ; $patchset ; git pull --rebase origin master"
    fi
  done
done

$SCP "$my_dir/../common/check-functions" $SSH_USER@$master_ip:check-functions
$SCP "$my_dir/__run-gate.sh" $SSH_USER@$master_ip:run-gate.sh
run_env+=" OPENSTACK_VERSION=$OPENSTACK_VERSION DOMAIN=$DOMAIN"
run_env+=" AGENT_MODE=$AGENT_MODE SSL_ENABLE=$SSL_ENABLE"
timeout -s 9 120m $SSH_CMD $SSH_USER@$master_ip "$run_env ./run-gate.sh"

check_introspection_cloud

trap - ERR
save_logs '2,3'
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi
