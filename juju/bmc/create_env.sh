#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

# base image for VMs is a xenial ubuntu cloud image with:
# 1) removed cloud-init
# 2) added jenkins's key to authorized keys for ubuntu user
# 3) added password '123' for user ubuntu
BASE_IMAGE_NAME=${BASE_IMAGE_NAME:-'ubuntu-xenial.qcow2'}
BASE_IMAGE_DIR=${BASE_IMAGE_DIR:-'/home/root/images'}
BASE_IMAGE="${BASE_IMAGE_DIR}/${BASE_IMAGE_NAME}"

source "$my_dir/functions"

trap 'catch_errors_ce $LINENO' ERR EXIT
function catch_errors_ce() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

# check if environment is present
if $virsh_cmd list --all | grep -q "juju-cont" ; then
  echo 'ERROR: environment present. please clean up first'
  $virsh_cmd list --all | grep "juju-"
  exit 1
fi

create_network $nname $addr

# create pool
$virsh_cmd pool-info $poolname &> /dev/null || create_pool $poolname
pool_path=$(get_pool_path $poolname)

function create_root_volume() {
  local name=$1
  delete_volume $name.qcow2 $poolname
  qemu-img create -f qcow2 -o preallocation=metadata $pool_path/$name.qcow2 $vm_disk_size
}

function run_machine() {
  local name="$1"
  local cpu="$2"
  local ram="$3"
  local mac_suffix="$4"

  echo "INFO: running  machine $name $(date)"

  cp $BASE_IMAGE $pool_path/$name.qcow2
  qemu-img resize $pool_path/$name.qcow2 +32G

  virt-install --name $name \
    --ram $ram \
    --vcpus $cpu \
    --virt-type kvm \
    --os-type=linux \
    --os-variant ubuntu16.04 \
    --disk path=$pool_path/$name.qcow2,cache=writeback,bus=virtio,serial=$(uuidgen) \
    --noautoconsole \
    --graphics vnc,listen=0.0.0.0 \
    --network network=$nname,model=$net_driver,mac=52:54:00:10:00:$mac_suffix \
    --cpu SandyBridge,+vmx \
    --boot hd
}

run_machine juju-cont 1 2048 $juju_cont_mac
cont_ip=`get_kvm_machine_ip $juju_cont_mac`

# wait for controller machine
iter=0
truncate -s 0 ./tmp_file
while ! scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -B ./tmp_file ubuntu@$cont_ip:/tmp/tmp_file ; do
  if (( iter >= 20 )) ; then
    echo "ERROR: Could not connect to controller"
    exit 1
  fi
  echo "INFO: Waiting for controller... $(date)"
  sleep 30
  ((++iter))
done

echo "INFO: bootstraping juju controller $(date)"
juju bootstrap manual/$cont_ip test-cloud

function run_compute() {
  local index=$1
  local mac_var_name="juju_os_comp_${1}_mac"
  local mac=${!mac_var_name}
  echo "INFO: creating compute $index (mac $mac) $(date)"
  run_machine juju-os-comp-$index 2 8192 $mac
  local ip=`get_kvm_machine_ip $mac`
  juju add-machine ssh:ubuntu@$ip
  echo "INFO: preparing compute $index $(date)"
  juju ssh ubuntu@$ip "sudo add-apt-repository -yu cloud-archive:newton ; sudo apt-get -fy install dpdk-igb-uio-dkms mc wget" &>>$log_dir/apt.log
}

function run_controller() {
  local index=$1
  local mac_var_name="juju_os_cont_${1}_mac"
  local mac=${!mac_var_name}
  echo "INFO: creating controller $index (mac $mac) $(date)"
  run_machine juju-os-cont-$index 4 16384 $mac
  local ip=`get_kvm_machine_ip $mac`
  juju add-machine ssh:ubuntu@$ip
  echo "INFO: preparing controller $index $(date)"
  juju ssh ubuntu@$ip "sudo apt-get -fy install mc wget bridge-utils" &>>$log_dir/apt.log
  juju ssh ubuntu@$ip "sudo sed -i -e 's/^USE_LXD_BRIDGE.*$/USE_LXD_BRIDGE=\"false\"/m' /etc/default/lxd-bridge"
  juju ssh ubuntu@$ip "sudo sed -i -e 's/^LXD_BRIDGE.*$/LXD_BRIDGE=\"br-ens3\"/m' /etc/default/lxd-bridge"
  juju scp "$my_dir/50-cloud-init.cfg" ubuntu@$ip:50-cloud-init.cfg
  juju ssh ubuntu@$ip "sudo cp ./50-cloud-init.cfg /etc/network/interfaces.d/50-cloud-init.cfg ; sudo reboot"
}

run_compute 1
run_compute 2

run_controller 1
if [ "$DEPLOY_AS_HA_MODE" == 'true' ] ; then
  run_controller 2
  run_controller 3
fi

echo "INFO: Environment created $(date)"

trap - ERR EXIT
