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

# DEPLOY_AS_HA_MODE = false/true

# disk size for overcloud machines
vm_disk_size="30G"
# volume's poolname
poolname="jujuimages"
net_driver=${net_driver:-e1000}
nname="juju"
addr="10.0.0"

source "$my_dir/functions"

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

function create_store_volume() {
  local name=$1
  delete_volume $name-store.qcow2 $poolname
  qemu-img create -f qcow2 -o preallocation=metadata $pool_path/$name-store.qcow2 100G
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

function get_machine_ip() {
  local mac_suffix="$1"
  for i in {1..10} ; do
    if python -c "import libvirt; conn = libvirt.open('$LIBVIRT_DEFAULT_URI'); ip = [lease['ipaddr'] for lease in conn.networkLookupByName('$nname').DHCPLeases() if lease['mac'] == '52:54:00:10:00:$mac_suffix'][0]; print ip" 2>/dev/null ; then
      break
    fi
    sleep 10
  done
}

run_machine juju-cont 1 2048 01
cont_ip=`get_machine_ip 01`

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

echo "INFO: creating compute 1 $(date)"
run_machine juju-os-comp-1 2 8192 02
ip=`get_machine_ip 02`
juju add-machine ssh:ubuntu@$ip
juju ssh $ip "sudo add-apt-repository cloud-archive:newton ; sudo apt-get -fy update ; sudo apt-get -fy install dpdk-igb-uio-dkms"
echo "INFO: creating compute 2 $(date)"
run_machine juju-os-comp-2 2 8192 03
ip=`get_machine_ip 03`
juju add-machine ssh:ubuntu@$ip
juju ssh $ip "sudo add-apt-repository cloud-archive:newton ; sudo apt-get -fy update ; sudo apt-get -fy install dpdk-igb-uio-dkms"

echo "INFO: creating controller 1 $(date)"
run_machine juju-os-cont-1 4 16384 05
ip=`get_machine_ip 05`
juju add-machine ssh:ubuntu@$ip

if [ "$DEPLOY_AS_HA_MODE" == 'true' ] ; then
  echo "INFO: creating controller 2 $(date)"
  run_machine juju-os-cont-2 4 16384 06
  ip=`get_machine_ip 06`
  juju add-machine ssh:ubuntu@$ip
  echo "INFO: creating controller 3 $(date)"
  run_machine juju-os-cont-3 4 16384 07
  ip=`get_machine_ip 07`
  juju add-machine ssh:ubuntu@$ip
fi
