#!/bin/bash -ea

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

# it should fail if Juju deployment is not found
source $my_dir/../../juju/bmc-contrail-R4/functions
juju-status-tabular
# ==============================================

$my_dir/../common/${HOST}/create-vm.sh
source "$my_dir/../common/${HOST}/ssh-defs"

trap 'catch_errors $LINENO' ERR
function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"

  save_logs '1-'
  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    $my_dir/../common/${HOST}/cleanup.sh
  fi

  exit $exit_code
}

if [[ "$CONTAINER_REGISTRY" == 'build' || "$CONTAINER_REGISTRY" == 'fullbuild' ]]; then
  build_containers
  CONTAINER_REGISTRY="$build_ip:5000"
  CONTRAIL_VERSION="$OPENSTACK_VERSION-$CONTRAIL_VERSION"
fi

# deploy cloud
source "$my_dir/../common/${HOST}/${ENVIRONMENT_OS}"

IP_CONT_01=`echo $nodes_cont_ips | cut -d ' ' -f 1`

# from juju
AUTH_IP=`get_machine_ip keystone`
METADATA_IP='127.0.0.1'
# use machine 0 as we know that this is compute
METADATA_PROXY_SECRET=`juju ssh 0 sudo grep metadata_proxy_secret /etc/contrail/contrail-vrouter-agent.conf 2>/dev/null | cut -d '=' -f 2 | tr -d ' '`

config=$WORKSPACE/contrail-ansible-deployer/instances.yaml
envsubst <$my_dir/instances.yaml.${HA}.tmpl >$config
echo "INFO: cloud config ------------------------- $(date)"
cat $config
cp $config $WORKSPACE/logs/

prepare_image centos-soft

mkdir -p $WORKSPACE/logs/deployer
volumes="-v $WORKSPACE/contrail-ansible-deployer:/root/contrail-ansible-deployer"
volumes+=" -v $HOME/.ssh:/.ssh"
volumes+=" -v $WORKSPACE/logs/deployer:/root/logs"
volumes+=" -v $my_dir/__run-gate.sh:/root/run-gate.sh"
docker run -i --rm --entrypoint /bin/bash $volumes --network host --cap-add NET_RAW --cap-add NET_ADMIN centos-soft -c "/root/run-gate.sh"

# TODO: wait till cluster up and initialized
sleep 120

# Validate cluster's introspection ports
for dest in $nodes_ips ; do
  $SCP "$my_dir/../__check_introspection.sh" $SSH_USER@${dest}:./check_introspection.sh
done
source "$my_dir/../common/check-functions"
res=0
ips=($nodes_ips)
dest_to_check="${SSH_USER}@${ips[0]}"
for ip in ${ips[@]:1} ; do
  dest_to_check="$dest_to_check,${SSH_USER}@$ip"
done
count=1
limit=3
while ! check_introspection "$dest_to_check" ; do
  echo "INFO: check_introspection ${count}/${limit} failed"
  if (( count == limit )) ; then
    echo "ERROR: Cloud was not up during timeout"
    res=1
    break
  fi
  (( count+=1 ))
  sleep 30
done
test $res == '0'

# save logs and exit
trap - ERR
save_logs '1-'
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi

exit $res
