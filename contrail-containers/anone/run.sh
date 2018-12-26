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
source $my_dir/../common/check-functions

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
IP_CONT_02=`echo $nodes_cont_ips | cut -d ' ' -f 2`
IP_CONT_03=`echo $nodes_cont_ips | cut -d ' ' -f 3`
IP_COMP_01=`echo $nodes_comp_ips | cut -d ' ' -f 1`
IP_COMP_02=`echo $nodes_comp_ips | cut -d ' ' -f 2`

config=$WORKSPACE/contrail-ansible-deployer/instances.yaml
envsubst <$my_dir/instances.yaml.${HA}.tmpl >$config
echo "INFO: cloud config ------------------------- $(date)"
cat $config
cp $config $WORKSPACE/logs/
$SCP $config root@${master_ip}:

prepare_image centos-soft

mkdir -p $WORKSPACE/logs/deployer
volumes="-v $WORKSPACE/contrail-ansible-deployer:/root/contrail-ansible-deployer"
volumes+=" -v $HOME/.ssh:/.ssh"
volumes+=" -v $WORKSPACE/logs/deployer:/root/logs"
volumes+=" -v $my_dir/__run-gate.sh:/root/run-gate.sh"
docker run -i --rm --entrypoint /bin/bash $volumes --network host centos-soft -c "/root/run-gate.sh"

# TODO: wait till cluster up and initialized
sleep 300

check_introspection_cloud

# save logs and exit
trap - ERR
save_logs '1-'
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi

exit $res
