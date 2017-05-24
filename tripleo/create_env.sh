#!/bin/bash -e

# suffix for deployment
if [[ -z "$NUM" ]] ; then
  echo "Please set NUM variable to specific environment number. (export NUM=4)"
  exit 1
fi

# number of machines in overcloud
# by default scripts will create hyperconverged environment with SDS on compute
CONTROLLER_COUNT=${CONTROLLER_COUNT:-3}
COMPUTE_COUNT=${COMPUTE_COUNT:-2}
STORAGE_COUNT=${STORAGE_COUNT:-0}
CONTRAIL_CONTROLLER_COUNT=${CONTRAIL_CONTROLLER_COUNT:-1}

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

# ready image for undercloud - using CentOS cloud image. just run and ssh into it.
BASE_IMAGE="/var/lib/images/CentOS-7-x86_64-GenericCloud-1607.qcow2"
# disk size for overcloud machines
vm_disk_size="30G"
# volume's poolname
poolname="rdimages"
net_driver=${net_driver:-e1000}

source "$my_dir/functions"

# check if environment is present
if virsh list --all | grep -q "rd-undercloud-$NUM" ; then
  echo 'ERROR: environment present. please clean up first'
  virsh list --all | grep "cloud-$NUM"
  exit 1
fi

# create three networks (i don't know why external is needed)
create_network management
mgmt_net=`get_network_name management`
create_network provisioning
prov_net=`get_network_name provisioning`
create_network external
ext_net=`get_network_name external`

# create pool
virsh pool-info $poolname &> /dev/null || create_pool $poolname
pool_path=$(get_pool_path $poolname)

function create_root_volume() {
  name=$1
  delete_volume $name.qcow2 $poolname
  qemu-img create -f qcow2 -o preallocation=metadata $pool_path/$name.qcow2 $vm_disk_size
}

function create_store_volume() {
  name=$1
  delete_volume $name-store.qcow2 $poolname
  qemu-img create -f qcow2 -o preallocation=metadata $pool_path/$name-store.qcow2 100G
}

# create volumes for overcloud machines
for (( i=1; i<=CONTROLLER_COUNT; i++ )) ; do
  name="overcloud-$NUM-cont-$i"
  create_root_volume $name
done
for (( i=1; i<=COMPUTE_COUNT; i++ )) ; do
  name="overcloud-$NUM-comp-$i"
  create_root_volume $name
  create_store_volume $name
done
for (( i=1 ; i<=STORAGE_COUNT; i++ )) ; do
  name="overcloud-$NUM-stor-$i"
  create_root_volume $name
  create_store_volume $name
done
for (( i=1 ; i<=CONTRAIL_CONTROLLER_COUNT; i++ )) ; do
  name="overcloud-$NUM-ctrlcont-$i"
  create_root_volume $name
done

# copy image for undercloud and resize them
cp $BASE_IMAGE $pool_path/undercloud-$NUM.qcow2
qemu-img resize $pool_path/undercloud-$NUM.qcow2 +32G

# define MAC's
mgmt_ip=$(get_network_ip "management")
mgmt_mac="00:16:00:00:0$NUM:02"
prov_ip=$(get_network_ip "provisioning")
prov_mac="00:16:00:00:0$NUM:06"
# generate password/key for undercloud's root
rm -f "$my_dir/kp-$NUM" "$my_dir/kp-$NUM.pub"
ssh-keygen -b 2048 -t rsa -f "$my_dir/kp-$NUM" -q -N ""
rootpass=`openssl passwd -1 123`

# TODO: use guestfish instead of manual attachment
# mount undercloud root disk. (it helps to create multienv)
# !!! WARNING !!! in case of errors you need to unmount/disconnect it manually!!!
qemu-nbd -n -c /dev/nbd3 $pool_path/undercloud-$NUM.qcow2
sleep 5
tmpdir=$(mktemp -d)
mount /dev/nbd3p1 $tmpdir
sleep 2

function change_undercloud_image() {
  # configure eth0 - management
  cp "$my_dir/ifcfg-ethM" $tmpdir/etc/sysconfig/network-scripts/ifcfg-eth0
  sed -i "s/{{network}}/$mgmt_ip/g" $tmpdir/etc/sysconfig/network-scripts/ifcfg-eth0
  sed -i "s/{{mac-address}}/$mgmt_mac/g" $tmpdir/etc/sysconfig/network-scripts/ifcfg-eth0
  sed -i "s/{{num}}/$NUM/g" $tmpdir/etc/sysconfig/network-scripts/ifcfg-eth0
  # configure eth1 - provisioning
  cp "$my_dir/ifcfg-ethA" $tmpdir/etc/sysconfig/network-scripts/ifcfg-eth1
  sed -i "s/{{network}}/$prov_ip/g" $tmpdir/etc/sysconfig/network-scripts/ifcfg-eth1
  sed -i "s/{{mac-address}}/$prov_mac/g" $tmpdir/etc/sysconfig/network-scripts/ifcfg-eth1
  # configure root access
  mkdir -p $tmpdir/root/.ssh
  cp "$my_dir/kp-$NUM.pub" $tmpdir/root/.ssh/authorized_keys
  echo "PS1='\${debian_chroot:+(\$debian_chroot)}undercloud:\[\033[01;31m\](\$?)\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\\\$ '" >> $tmpdir/root/.bashrc
  sed -i "s root:\*: root:$rootpass: " $tmpdir/etc/shadow
  sed -i "s root:\!\!: root:$rootpass: " $tmpdir/etc/shadow
  grep root $tmpdir/etc/shadow
  echo "PermitRootLogin yes" > $tmpdir/etc/ssh/sshd_config
}

ret=0
change_undercloud_image || ret=1

# unmount disk
umount /dev/nbd3p1
sleep 2
rm -rf $tmpdir
qemu-nbd -d /dev/nbd3
sleep 2

if [[ $ret != 0 ]] ; then
  echo "ERROR: there were errors in changing undercloud image"
  exit 1
fi

# define and start undercloud machine
virt-install --name=rd-undercloud-$NUM \
  --ram=8192 \
  --vcpus=1,cores=1 \
  --os-type=linux \
  --os-variant=rhel7 \
  --virt-type=kvm \
  --disk "path=$pool_path/undercloud-$NUM.qcow2",size=40,cache=writeback,bus=virtio,serial=$(uuidgen) \
  --boot hd \
  --noautoconsole \
  --network network=$mgmt_net,model=$net_driver,mac=$mgmt_mac \
  --network network=$prov_net,model=$net_driver,mac=$prov_mac \
  --network network=$ext_net,model=$net_driver \
  --graphics vnc,listen=0.0.0.0

function define-machine() {
  name="$1"
  shift
  disk_opt="$@"
  virt-install --name $name \
    --ram 8192 \
    --vcpus 2 \
    --os-variant rhel7 \
    $disk_opt \
    --noautoconsole \
    --vnc \
    --network network=$prov_net,model=$net_driver \
    --network network=$ext_net,model=$net_driver \
    --cpu SandyBridge,+vmx \
    --dry-run --print-xml > /tmp/oc-$name.xml
  virsh define --file /tmp/oc-$name.xml
}

# just define overcloud machines
for (( i=1; i<=CONTROLLER_COUNT; i++ )) ; do
  name="overcloud-$NUM-cont-$i"
  define-machine rd-$name "--disk path=$pool_path/$name.qcow2,device=disk,bus=virtio,format=qcow2"
done
for (( i=1; i<=COMPUTE_COUNT; i++ )) ; do
  name="overcloud-$NUM-comp-$i"
  define-machine rd-$name "--disk path=$pool_path/$name.qcow2,device=disk,bus=virtio,format=qcow2 --disk path=$pool_path/$name-store.qcow2,device=disk,bus=virtio,format=qcow2"
done
for (( i=1; i<=STORAGE_COUNT; i++ )) ; do
  name="overcloud-$NUM-stor-$i"
  define-machine rd-$name "--disk path=$pool_path/$name.qcow2,device=disk,bus=virtio,format=qcow2 --disk path=$pool_path/$name-store.qcow2,device=disk,bus=virtio,format=qcow2"
done
for (( i=1; i<=CONTRAIL_CONTROLLER_COUNT; i++ )) ; do
  name="overcloud-$NUM-ctrlcont-$i"
  define-machine rd-$name "--disk path=$pool_path/$name.qcow2,device=disk,bus=virtio,format=qcow2"
done


# wait for undercloud machine
iter=0
truncate -s 0 ./tmp_file
while ! scp -i "$my_dir/kp-$NUM" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -B ./tmp_file root@${mgmt_ip}.2:/tmp/tmp_file ; do
  if (( iter >= 20 )) ; then
    echo "Could not connect to undercloud"
    exit 1
  fi
  echo "Waiting for undercloud..."
  sleep 30
  ((++iter))
done
