#!/bin/bash -ex

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

source "$my_dir/functions"

# check if environment is present
if virsh list --all | grep -q "juju-cont" ; then
  echo 'ERROR: environment present. please clean up first'
  virsh list --all | grep "juju-"
  exit 1
fi

nname="juju"
addr="10.0.0"
create_network $nname $addr

# create pool
virsh pool-info $poolname &> /dev/null || create_pool $poolname
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

  cp $BASE_IMAGE $pool_path/juju-$name.qcow2
  qemu-img resize $pool_path/juju-$name.qcow2 +32G

  virt-install --name $name \
    --ram $ram \
    --vcpus $cpu \
    --virt-type kvm \
    --os-type=linux \
    --os-variant ubuntuxenial \
    --disk path=$pool_path/juju-$name.qcow2,cache=writeback,bus=virtio,serial=$(uuidgen) \
    --noautoconsole \
    --graphics vnc,listen=0.0.0.0 \
    --network network=$nname,model=$net_driver,mac=52:54:00:10:00:$mac_suffix \
    --cpu SandyBridge,+vmx
}

function get_machine_ip() {
  local mac_suffix="$1"
  python -c "import libvirt; conn = libvirt.open('qemu:///system'); ip = [lease['ipaddr'] for lease in conn.networkLookupByName('$nname').DHCPLeases() if lease['mac'] == '52:54:00:10:00:$mac_suffix'][0]; print ip"
}

run_machine cont 1 2048 01
cont_ip=`get_machine_ip 01`

# wait for controller machine
iter=0
truncate -s 0 ./tmp_file
while ! scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -B ./tmp_file ubuntu@$cont_ip:/tmp/tmp_file ; do
  if (( iter >= 20 )) ; then
    echo "Could not connect to controller"
    exit 1
  fi
  echo "Waiting for controller..."
  sleep 30
  ((++iter))
done

# juju bootstrap manual/$cont_ip test-cloud

