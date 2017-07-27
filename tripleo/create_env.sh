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

if [[ -z "$DPDK" ]] ; then
  echo "DPDK is expected (e.g. export DPDK=yes/no)"
  exit 1
fi

if [[ "$DPDK" != 'yes' ]] ; then
compute_machine_name='comp'
else
compute_machine_name='compdpdk'
fi

RHEL_CERT_TEST=${RHEL_CERT_TEST:-'no'}

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ssh_key_dir="/home/jenkins"

# base image for VMs
BASE_IMAGE_NAME=${BASE_IMAGE_NAME:-"undercloud-${ENVIRONMENT_OS}-${OPENSTACK_VERSION}.qcow2"}
BASE_IMAGE_DIR=${BASE_IMAGE_DIR:-'/home/root/images'}
mkdir -p ${BASE_IMAGE_DIR}
BASE_IMAGE="${BASE_IMAGE_DIR}/${BASE_IMAGE_NAME}"

# number of machines in overcloud
# by default scripts will create hyperconverged environment with SDS on compute
CONTROLLER_COUNT=${CONTROLLER_COUNT:-1}
COMPUTE_COUNT=${COMPUTE_COUNT:-2}
STORAGE_COUNT=${STORAGE_COUNT:-0}
CONTRAIL_CONTROLLER_COUNT=${CONTRAIL_CONTROLLER_COUNT:-1}
CONTRAIL_ANALYTICS_COUNT=${CONTRAIL_ANALYTICS_COUNT:-1}
CONTRAIL_ANALYTICSDB_COUNT=${CONTRAIL_ANALYTICSDB_COUNT:-1}

# Dir with contrail packages
CONTRAIL_PACKAGES_DIR=${CONTRAIL_PACKAGES_DIR:-'/home/root/contrail/latest'}

# ready image for undercloud - using CentOS cloud image. just run and ssh into it.
if [[ ! -f ${BASE_IMAGE} ]] ; then
  if [[ "$ENVIRONMENT_OS" == "centos" ]] ; then
    wget -O ${BASE_IMAGE} https://cloud.centos.org/centos/7/images/${BASE_IMAGE_NAME}
  else
    echo Download of image is implemented only for CentOS based environment
    exit 1
  fi
fi

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
  local name=$1
  delete_volume $name.qcow2 $poolname
  qemu-img create -f qcow2 -o preallocation=metadata $pool_path/$name.qcow2 $vm_disk_size
}

function create_store_volume() {
  local name=$1
  delete_volume $name-store.qcow2 $poolname
  qemu-img create -f qcow2 -o preallocation=metadata $pool_path/$name-store.qcow2 100G
}

function define-machine() {
  local name="$1"
  shift
  local disk_opt="$@"
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

function define_overcloud_vms() {
  local name=$1
  local count=$2
  local do_create_storage=${3:-'false'}
  local number_re='^[0-9]+$'
  if [[ $count =~ $number_re ]] ; then
    for (( i=1 ; i<=count; i++ )) ; do
      local vol_name="overcloud-$NUM-${name}-$i"
      create_root_volume $vol_name
      local disk_opts="--disk path=${pool_path}/${vol_name}.qcow2,device=disk,bus=virtio,format=qcow2"
      if [[ "$do_create_storage" == 'true' ]] ; then
        create_store_volume $vol_name
        disk_opts+=" --disk path=${pool_path}/${vol_name}-store.qcow2,device=disk,bus=virtio,format=qcow2"
      fi
      define-machine "rd-$vol_name" "$disk_opts"
    done
  else
    echo Skip VM $name creation, count=$count
  fi
}

# just define overcloud machines
define_overcloud_vms 'cont' $CONTROLLER_COUNT
define_overcloud_vms $compute_machine_name $COMPUTE_COUNT 'true'
define_overcloud_vms 'stor' $STORAGE_COUNT 'true'
define_overcloud_vms 'ctrlcont' $CONTRAIL_CONTROLLER_COUNT
define_overcloud_vms 'ctrlanalytics' $CONTRAIL_ANALYTICS_COUNT
define_overcloud_vms 'ctrlanalyticsdb' $CONTRAIL_ANALYTICSDB_COUNT

# copy image for undercloud and resize them
cp $BASE_IMAGE $pool_path/undercloud-$NUM.qcow2

# for RHEL make a copy of disk to run one more VM for test server
if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  if [[ "$RHEL_CERT_TEST" == 'yes' ]] ; then
    cp $pool_path/undercloud-$NUM.qcow2 $pool_path/undercloud-$NUM-cert-test.qcow2
  fi
fi

# define MAC's
mgmt_ip=$(get_network_ip "management")
mgmt_mac="00:16:00:00:0$NUM:02"
mgmt_mac_cert="00:16:00:01:0$NUM:02"

prov_ip=$(get_network_ip "provisioning")
prov_mac="00:16:00:00:0$NUM:06"
prov_mac_cert="00:16:00:01:0$NUM:06"

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

  # prepare contrail pkgs
  if [[ "$prepare_contrail_pkgs" == 'yes' ]] ; then
    rm -rf $tmpdir/root/contrail_packages
    mkdir -p $tmpdir/root/contrail_packages
    cp $CONTRAIL_PACKAGES_DIR/*.tgz $tmpdir/root/contrail_packages/
    cp $CONTRAIL_PACKAGES_DIR/*${OPENSTACK_VERSION}*.rpm $tmpdir/root/contrail_packages/
  fi
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
    --vcpus=1,cores=1 \
    --os-type=linux \
    --os-variant=rhel7 \
    --virt-type=kvm \
    --disk "path=$image",size=40,cache=writeback,bus=virtio,serial=$(uuidgen) \
    --boot hd \
    --noautoconsole \
    --network network=$mgmt_net,model=$net_driver,mac=$mgmt_mac \
    --network network=$prov_net,model=$net_driver,mac=$prov_mac \
    --network network=$ext_net,model=$net_driver \
    --graphics vnc,listen=0.0.0.0

}

_patch_image "$pool_path/undercloud-$NUM.qcow2" \
  'ifcfg-ethM' $mgmt_ip $mgmt_mac \
  'ifcfg-ethA' $prov_ip $prov_mac

_start_vm "rd-undercloud-$NUM" "$pool_path/undercloud-$NUM.qcow2" $mgmt_mac $prov_mac

if [[ "$RHEL_CERT_TEST" == 'yes' ]] ; then
  _patch_image "$pool_path/undercloud-$NUM-cert-test.qcow2" \
    'ifcfg-ethMC' $mgmt_ip $mgmt_mac_cert \
    'ifcfg-ethAC' $prov_ip $prov_mac_cert \
    'no'

  _start_vm "rd-undercloud-$NUM-cert-test" "$pool_path/undercloud-$NUM-cert-test.qcow2" $mgmt_mac_cert $prov_mac_cert 4096
fi

# wait for undercloud machine
function _wait_machine() {
  local addr=$1
  local max_iter=${2:-20}
  local iter=0
  truncate -s 0 ./tmp_file
  while ! scp -i "$ssh_key_dir/kp-$NUM" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -B ./tmp_file root@${addr}:/tmp/tmp_file ; do
    if (( iter >= max_iter )) ; then
      echo "Could not connect to undercloud"
      exit 1
    fi
    echo "Waiting for undercloud..."
    sleep 30
    ((++iter))
  done
}

_wait_machine "${mgmt_ip}.2"

if [[ "$RHEL_CERT_TEST" == 'yes' ]] ; then
  _wait_machine "${mgmt_ip}.3"

  ssh_cmd="ssh -i $ssh_key_dir/kp-$NUM -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@${mgmt_ip}.3"
  $ssh_cmd "yum install -y redhat-certification && systemctl start httpd && rhcertd start"

  $ssh_cmd "sed -i \"s/ALLOWED_HOSTS =.*/ALLOWED_HOSTS = ['${mgmt_ip}.3', '${prov_ip}.201', 'localhost.localdomain', 'localhost', '127.0.0.1']/\" /var/www/rhcert/project/settings.py"
  $ssh_cmd systemctl restart httpd
fi