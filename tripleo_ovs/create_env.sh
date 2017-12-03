#!/bin/bash -ex

# suffix for deployment
if [[ -z "$NUM" ]] ; then
  echo "Please set NUM variable to specific environment number. (export NUM=4)"
  exit 1
fi

if [[ -z "$OPENSTACK_VERSION" ]] ; then
  echo "OPENSTACK_VERSION is expected (e.g. export OPENSTACK_VERSION=newton)"
  exit 1
fi

if [[ -z "$ENVIRONMENT_OS" ]] ; then
  echo "ENVIRONMENT_OS is expected (e.g. export ENVIRONMENT_OS=centos)"
  exit 1
fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ssh_key_dir="/home/jenkins"

# base image for VMs
if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  DEFAULT_BASE_IMAGE_NAME="undercloud-${ENVIRONMENT_OS}-${ENVIRONMENT_OS_VERSION}-${OPENSTACK_VERSION}.qcow2"
else
  DEFAULT_BASE_IMAGE_NAME="undercloud-${ENVIRONMENT_OS}-${OPENSTACK_VERSION}.qcow2"
fi
BASE_IMAGE_NAME=${BASE_IMAGE_NAME:-"$DEFAULT_BASE_IMAGE_NAME"}
BASE_IMAGE_DIR=${BASE_IMAGE_DIR:-'/home/root/images'}
mkdir -p ${BASE_IMAGE_DIR}
BASE_IMAGE="${BASE_IMAGE_DIR}/${BASE_IMAGE_NAME}"
BASE_IMAGE_POOL=${BASE_IMAGE_POOL:-'images'}

# number of machines in overcloud
# by default scripts will create hyperconverged environment with SDS on compute
CONTROLLER_COUNT=${CONTROLLER_COUNT:-1}
COMPUTE_COUNT=${COMPUTE_COUNT:-2}
STORAGE_COUNT=${STORAGE_COUNT:-2}

# disk size for overcloud machines
vm_disk_size="30G"
# volume's poolname
poolname="rdimages"
net_driver=${net_driver:-e1000}

source "$my_dir/../common/virsh/functions"

# check if environment is present
assert_env_exists "rd-undercloud-$NUM"

# create three networks (i don't know why external is needed)
create_network management
mgmt_net=`get_network_name management`
create_network provisioning
prov_net=`get_network_name provisioning`

# create pool
create_pool $poolname

function define_overcloud_vms() {
  local name=$1
  local count=$2
  local mem=$3
  local disk_size=${4:-40}
  local number_re='^[0-9]+$'
  if [[ $count =~ $number_re ]] ; then
    for (( i=1 ; i<=count; i++ )) ; do
      local vol_name="overcloud-$NUM-${name}-$i"
      local vol_path=$(create_new_volume $vol_name $poolname $disk_size)
      define_machine "rd-$vol_name" 2 $mem rhel7 $prov_net "$vol_path"
    done
  else
    echo Skip VM $name creation, count=$count
  fi
}

# just define overcloud machines
define_overcloud_vms 'cont' $CONTROLLER_COUNT 8192
define_overcloud_vms 'comp' $COMPUTE_COUNT 4096
define_overcloud_vms 'stor' $STORAGE_COUNT 4096

# copy image for undercloud and resize them
local undercloud_vol_path=$(create_volume_from $undercloud-$NUM.qcow2 $poolname $BASE_IMAGE_NAME $BASE_IMAGE_POOL)

# define MAC's
mgmt_ip=$(get_network_ip "management")
mgmt_mac="00:17:00:00:0$NUM:02"
prov_ip=$(get_network_ip "provisioning")
prov_mac="00:17:00:00:0$NUM:06"

# generate password/key for undercloud's root
rm -f "$ssh_key_dir/kp-$NUM" "$ssh_key_dir/kp-$NUM.pub"
ssh-keygen -b 2048 -t rsa -f "$ssh_key_dir/kp-$NUM" -q -N ""
rootpass=`openssl passwd -1 123`

#check that nbd kernel module is loaded
if ! lsmod |grep '^nbd ' ; then
  modprobe nbd max_part=8
fi

function _change_iface() {
  local templ=$1
  local iface=$2
  local network=$3
  local mac=$4
  local iface_file=$tmpdir/etc/sysconfig/network-scripts/ifcfg-$iface
  cp "$my_dir/$templ" $iface_file
  sed -i "s/{{network}}/$network/g" $iface_file
  sed -i "s/{{mac-address}}/$mac/g" $iface_file
  sed -i "s/{{num}}/$NUM/g" $iface_file
}

function _change_image() {
  local mgmt_templ=$1
  local mgmt_network=$2
  local mgmt_mac=$3
  local prov_templ=$4
  local prov_network=$5
  local prov_mac=$6
  local prepare_contrail_pkgs=$7

  # configure eth0 - management
  _change_iface $mgmt_templ 'eth0' $mgmt_network $mgmt_mac

  # configure eth1 - provisioning
  _change_iface $prov_templ 'eth1' $prov_network $prov_mac

  # configure root access
  mkdir -p $tmpdir/root/.ssh
  cp "$ssh_key_dir/kp-$NUM.pub" $tmpdir/root/.ssh/authorized_keys
  cp "/home/stack/.ssh/id_rsa" $tmpdir/root/stack_id_rsa
  cp "/home/stack/.ssh/id_rsa.pub" $tmpdir/root/stack_id_rsa.pub
  echo "PS1='\${debian_chroot:+(\$debian_chroot)}undercloud:\[\033[01;31m\](\$?)\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\\\$ '" >> $tmpdir/root/.bashrc
  sed -i "s root:\*: root:$rootpass: " $tmpdir/etc/shadow
  sed -i "s root:\!\!: root:$rootpass: " $tmpdir/etc/shadow
  grep root $tmpdir/etc/shadow
  echo "PermitRootLogin yes" > $tmpdir/etc/ssh/sshd_config
}

function _patch_image() {
  local image=$1
  local mgmt_templ=$2
  local mgmt_network=$3
  local mgmt_mac=$4
  local prov_templ=$5
  local prov_network=$6
  local prov_mac=$7
  local prepare_contrail_pkgs=${8:-'yes'}

  # TODO: use guestfish instead of manual attachment
  # mount undercloud root disk. (it helps to create multienv)
  # !!! WARNING !!! in case of errors you need to unmount/disconnect it manually!!!
  local nbd_dev="/dev/nbd${NUM}"
  qemu-nbd -d $nbd_dev || true
  qemu-nbd -n -c $nbd_dev $image
  sleep 5
  local ret=0
  local tmpdir=$(mktemp -d)
  mount ${nbd_dev}p1 $tmpdir || ret=1
  sleep 2

  # patch image
  [ $ret == 0 ] && _change_image \
    $mgmt_templ $mgmt_network $mgmt_mac \
    $prov_templ $prov_network $prov_mac \
    $prepare_contrail_pkgs || ret=2

  # unmount disk
  [ $ret != 1 ] && umount ${nbd_dev}p1 || ret=2
  sleep 2
  rm -rf $tmpdir || ret=3
  qemu-nbd -d $nbd_dev || ret=4
  sleep 2

  if [[ $ret != 0 ]] ; then
    echo "ERROR: there were errors in changing image $image, ret=$ret"
    exit 1
  fi
}

function _start_vm() {
  local name=$1
  local image=$2
  local mgmt_mac=$3
  local prov_mac=$4
  local ram=${5:-16384}

  # define and start machine
  virt-install --name=$name \
    --ram=$ram \
    --vcpus=1,cores=2 \
    --os-type=linux \
    --os-variant=rhel7 \
    --virt-type=kvm \
    --disk "path=$image",size=40,cache=writeback,bus=virtio,serial=$(uuidgen) \
    --boot hd \
    --noautoconsole \
    --network network=$mgmt_net,model=$net_driver,mac=$mgmt_mac \
    --network network=$prov_net,model=$net_driver,mac=$prov_mac \
    --graphics vnc,listen=0.0.0.0
}

_patch_image "$undercloud_vol_path" \
  'ifcfg-ethM' $mgmt_ip $mgmt_mac \
  'ifcfg-ethA' $prov_ip $prov_mac

_start_vm "rd-undercloud-$NUM" "$undercloud_vol_path" \
  $mgmt_mac $prov_mac

ssh_opts="-i $ssh_key_dir/kp-$NUM -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ssh_cmd="ssh -T $ssh_opts"

# wait for undercloud machine
function _wait_machine() {
  local addr=$1
  wait_ssh $addr "$ssh_key_dir/kp-$NUM"
}

function _prepare_network() {
  local addr=$1
  local my_host=$2
  cat <<EOF | $ssh_cmd root@${addr}
set -x
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p /etc/sysctl.conf
hostnamectl set-hostname $my_host
hostnamectl set-hostname --transient $my_host
echo "127.0.0.1   localhost myhost $my_host" > /etc/hosts
systemctl restart network
sleep 5
EOF
}

# wait udnercloud and register it in redhat if rhel env
_wait_machine "${mgmt_ip}.2"
_prepare_network "${mgmt_ip}.2"  "myhost.my${NUM}domain"
