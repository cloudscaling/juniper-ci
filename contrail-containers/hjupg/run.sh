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
source $my_dir/../common/check-functions

# it should fail if Juju deployment is not found
source $my_dir/../../juju/bmc-contrail-R4/functions
juju-status-tabular
# ==============================================

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
  build_containers
  run_env="CONTAINER_REGISTRY=$build_ip:5000 CONTRAIL_VERSION=$OPENSTACK_VERSION-$CONTRAIL_VERSION REGISTRY_INSECURE=1"
else
  run_env="CONTAINER_REGISTRY=$CONTAINER_REGISTRY CONTRAIL_VERSION=$CONTRAIL_VERSION REGISTRY_INSECURE=0"
fi

# tune iptables on KVM
prepare_image centos-soft
docker run -i --rm --entrypoint /bin/bash -v $my_dir/__fix-iptables.sh:/root/fix-iptables.sh --network host --cap-add NET_RAW --cap-add NET_ADMIN centos-soft -c "/root/fix-iptables.sh"

# from juju
AUTH_IP=`get_machine_ip keystone`
METADATA_IP='127.0.0.1'
# use machine 0 as we know that this is compute
METADATA_PROXY_SECRET=`juju ssh 0 sudo grep metadata_proxy_secret /etc/contrail/contrail-vrouter-agent.conf 2>/dev/null | cut -d '=' -f 2 | tr -d ' '`

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

$SCP "$my_dir/../common/check-functions" $SSH_USER@$master_ip:check-functions
$SCP "$my_dir/__run-gate.sh" $SSH_USER@$master_ip:run-gate.sh
run_env+=" OPENSTACK_VERSION=$OPENSTACK_VERSION"
run_env+=" AGENT_MODE=$AGENT_MODE SSL_ENABLE=$SSL_ENABLE"
run_env+=" AUTH_IP=$AUTH_IP METADATA_IP=$METADATA_IP METADATA_PROXY_SECRET=$METADATA_PROXY_SECRET"
timeout -s 9 120m $SSH_CMD $SSH_USER@$master_ip "$run_env ./run-gate.sh"


# TODO: wait till cluster up and initialized
sleep 30

check_introspection_cloud

trap - ERR
save_logs '2,3'
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi
