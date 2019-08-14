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

  save_logs '1-'
  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    $my_dir/../common/${HOST}/cleanup.sh
  fi

  exit $exit_code
}

if [[ "$CONTAINER_REGISTRY" == 'build' || "$CONTAINER_REGISTRY" == 'fullbuild' ]]; then
  source "$my_dir/../common/${HOST}/definitions"
  build_containers
  CONTAINER_REGISTRY="$build_ip:5000"
  CONTRAIL_VERSION="$OPENSTACK_VERSION-$CONTRAIL_VERSION"
fi

# deploy cloud
source "$my_dir/../common/${HOST}/${ENVIRONMENT_OS}"

prepare_image centos-soft
clone_clean_and_patched_repo contrail-ansible-deployer

IP_VM_01=`echo $nodes_cont_ips | cut -d ' ' -f 1`
IP_VM_04=`echo $nodes_comp_ips | cut -d ' ' -f 1`
IP_VM_05=`echo $nodes_comp_ips | cut -d ' ' -f 2`

IP0_COMP_01=`echo $nodes_comp_ips_0 | cut -d ' ' -f 1`
IP0_COMP_02=`echo $nodes_comp_ips_0 | cut -d ' ' -f 2`

IP0_CONT_01=`echo ${nodes_cont_ips_0} | cut -d ' ' -f 1` ; IP0_CONT_01=`get_address $IP_VM_01 $IP0_CONT_01`
IP1_CONT_01=`echo ${nodes_cont_ips_1} | cut -d ' ' -f 1` ; IP1_CONT_01=`get_address $IP_VM_01 $IP1_CONT_01`
IP2_CONT_01=`echo ${nodes_cont_ips_2} | cut -d ' ' -f 1` ; IP2_CONT_01=`get_address $IP_VM_01 $IP2_CONT_01`
if [[ "$HA" == 'ha' ]] ; then
  IP_VM_02=`echo $nodes_cont_ips | cut -d ' ' -f 2`
  IP_VM_03=`echo $nodes_cont_ips | cut -d ' ' -f 3`

  IP0_CONT_02=`echo ${nodes_cont_ips_0} | cut -d ' ' -f 2` ; IP0_CONT_02=`get_address $IP_VM_02 $IP0_CONT_02`
  IP1_CONT_02=`echo ${nodes_cont_ips_1} | cut -d ' ' -f 2` ; IP1_CONT_02=`get_address $IP_VM_02 $IP1_CONT_02`
  IP2_CONT_02=`echo ${nodes_cont_ips_2} | cut -d ' ' -f 2` ; IP2_CONT_02=`get_address $IP_VM_02 $IP2_CONT_02`

  IP0_CONT_03=`echo ${nodes_cont_ips_0} | cut -d ' ' -f 3` ; IP0_CONT_03=`get_address $IP_VM_03 $IP0_CONT_03`
  IP1_CONT_03=`echo ${nodes_cont_ips_1} | cut -d ' ' -f 3` ; IP1_CONT_03=`get_address $IP_VM_03 $IP1_CONT_03`
  IP2_CONT_03=`echo ${nodes_cont_ips_2} | cut -d ' ' -f 3` ; IP2_CONT_03=`get_address $IP_VM_03 $IP2_CONT_03`

  E_VIP="$nodes_vip_0"
  I_VIP="$nodes_vip_1"
  CONTROLLER_NODES="${IP1_CONT_01},${IP1_CONT_02},${IP1_CONT_03}"
  CONTROL_NODES="${IP2_CONT_01},${IP2_CONT_02},${IP2_CONT_03}"

  # we use the same name for vrouter as hypervisor...
  HOSTNAME_VM_04=`$SSH_CMD ${SSH_USER}@${IP_VM_04} "getent hosts ${IP0_COMP_01}" 2>/dev/null | awk '{print $2}'`
  HOSTNAME_VM_05=`$SSH_CMD ${SSH_USER}@${IP_VM_05} "getent hosts ${IP0_COMP_02}" 2>/dev/null | awk '{print $2}'`
else
  CONTROLLER_NODES="${IP0_CONT_01}"
  CONTROL_NODES="${IP0_CONT_01}"
  #CONTROLLER_NODES="${IP1_CONT_01}"
  #CONTROL_NODES="${IP2_CONT_01}"

  # we use the same name for vrouter as hypervisor...
  HOSTNAME_VM_04=`$SSH_CMD ${SSH_USER}@${IP_VM_04} "getent hosts ${IP0_COMP_01}" 2>/dev/null | awk '{print $2}'`
  HOSTNAME_VM_05=`$SSH_CMD ${SSH_USER}@${IP_VM_05} "getent hosts ${IP0_COMP_02}" 2>/dev/null | awk '{print $2}'`
fi


if [[ "$HOST" == 'aws' ]]; then
  VIRT_TYPE=qemu
else
  VIRT_TYPE=kvm
fi

config=$WORKSPACE/contrail-ansible-deployer/instances.yaml
envsubst <$my_dir/instances.yaml.${HA}.tmpl >$config
echo "INFO: cloud config ------------------------- $(date)"
cat $config
cp $config $WORKSPACE/logs/
$SCP $config ${SSH_USER}@${master_ip}:

if echo "$PATCHSET_LIST" | grep -q "/contrail-kolla-ansible " ; then
  patchset=`echo "$PATCHSET_LIST" | grep "/contrail-kolla-ansible "`
fi

mkdir -p $WORKSPACE/logs/deployer
volumes="-v $WORKSPACE/contrail-ansible-deployer:/root/contrail-ansible-deployer"
volumes+=" -v $HOME/.ssh:/.ssh"
volumes+=" -v $WORKSPACE/logs/deployer:/root/logs"
volumes+=" -v $my_dir/__run-gate.sh:/root/run-gate.sh"
docker run -i --rm --entrypoint /bin/bash $volumes --network host -e KOLLA_PATCHSET_CMD="$patchset" -e OPENSTACK_VERSION=$OPENSTACK_VERSION -e VIRT_TYPE=$VIRT_TYPE centos-soft -c "/root/run-gate.sh"

# TODO: wait till cluster up and initialized
sleep 60

check_introspection_cloud

# validate openstack
source $my_dir/../common/check-functions
cd $WORKSPACE
$SSH_CMD ${SSH_USER}@$master_ip "sudo cat /etc/kolla/kolla-toolbox/admin-openrc.sh" > $WORKSPACE/admin-openrc.sh
virtualenv $WORKSPACE/.venv
source $WORKSPACE/.venv/bin/activate
source $WORKSPACE/admin-openrc.sh
if ! command -v pip ; then
  # TODO: move these checks with pip into container
  echo "ERROR: please install python-pip manually to the deployer node"
  res=1
else
  pip install python-openstackclient || res=1
  if ! prepare_openstack ; then
    echo "ERROR: OpenStack preparation failed"
    res=1
  else
    check_simple_instance || res=1
    check_two_instances || res=1
  fi
fi
deactivate

# save logs and exit
trap - ERR
save_logs '1-'
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi

exit $res
