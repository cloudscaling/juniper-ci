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
  echo "DPDK is expected (e.g. export DPDK=true/false)"
  exit 1
fi

if [[ -z "$TSN" ]] ; then
  echo "TSN is expected (e.g. export TSN=true/false)"
  exit 1
fi

if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  if [[ -z "$RHEL_ACCOUNT_FILE" ]] ; then
    echo "ERROR: for rhel environemnt the environment variable RHEL_ACCOUNT_FILE is required"
    exit 1
  fi
else
  if [[ "$RHEL_CERT_TEST" == 'true' ]] ; then
    echo "ERROR: RHEL_CERT_TEST is supported only for RHEL environment"
    exit 1
  fi
fi

if [[ "$DPDK" == 'true' ]] ; then
  compute_machine_name='compdpdk'
elif [[ "$TSN" == 'true' ]] ; then
  compute_machine_name='comptsn'
else
  compute_machine_name='comp'
fi

RHEL_CERT_TEST=${RHEL_CERT_TEST:-'false'}

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

# number of machines in overcloud
# by default scripts will create hyperconverged environment with SDS on compute
CONTROLLER_COUNT=${CONTROLLER_COUNT:-1}
COMPUTE_COUNT=${COMPUTE_COUNT:-2}
STORAGE_COUNT=${STORAGE_COUNT:-0}
CONTRAIL_CONTROLLER_COUNT=${CONTRAIL_CONTROLLER_COUNT:-1}
CONTRAIL_ANALYTICS_COUNT=${CONTRAIL_ANALYTICS_COUNT:-1}
CONTRAIL_ANALYTICSDB_COUNT=${CONTRAIL_ANALYTICSDB_COUNT:-1}

# ready image for undercloud - using CentOS cloud image. just run and ssh into it.
if [[ ! -f ${BASE_IMAGE} ]] ; then
  if [[ "$ENVIRONMENT_OS" == "centos" ]] ; then
    wget -O ${BASE_IMAGE} https://cloud.centos.org/centos/7/images/${BASE_IMAGE_NAME}
  else
    echo "Download of image is implemented only for CentOS based environment"
    exit 1
  fi
fi

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
#create_network external
#ext_net=`get_network_name external`
#create_network dpdk
#dpdk_net=`get_network_name dpdk`
#create_network tsn
#tsn_net=`get_network_name tsn`

# create pool
create_pool $poolname
pool_path=$(get_pool_path $poolname)

function create_root_volume() {
  local name=$1
  create_volume $name $poolname $vm_disk_size
}

function create_store_volume() {
  local name="${1}-store"
  create_volume $name $poolname 100G
}

function define_overcloud_vms() {
  local name=$1
  local count=$2
  local mem=$3
  local number_re='^[0-9]+$'
  if [[ $count =~ $number_re ]] ; then
    for (( i=1 ; i<=count; i++ )) ; do
      local vol_name="overcloud-$NUM-${name}-$i"
      create_root_volume $vol_name
      define_machine "rd-$vol_name" 2 $mem rhel7 $prov_net "${pool_path}/${vol_name}.qcow2"
    done
  else
    echo Skip VM $name creation, count=$count
  fi
}

# just define overcloud machines
define_overcloud_vms 'cont' $CONTROLLER_COUNT 8192
define_overcloud_vms $compute_machine_name $COMPUTE_COUNT 2048 'true'
define_overcloud_vms 'stor' $STORAGE_COUNT 4096 'true'
define_overcloud_vms 'ctrlcont' $CONTRAIL_CONTROLLER_COUNT 8192
define_overcloud_vms 'ctrlanalytics' $CONTRAIL_ANALYTICS_COUNT 4096
define_overcloud_vms 'ctrlanalyticsdb' $CONTRAIL_ANALYTICSDB_COUNT 8192

# copy image for undercloud and resize them
cp $BASE_IMAGE $pool_path/undercloud-$NUM.qcow2

# for RHEL make a copy of disk to run one more VM for test server
if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  if [[ "$RHEL_CERT_TEST" == 'true' ]] ; then
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
  if [[ "$CONTRAIL_SERIES" == 'release' ]] ; then
    build_series=''
  else
    build_series='cb-'
  fi

  if [[ "$prepare_contrail_pkgs" == 'yes' ]] ; then
    rm -rf $tmpdir/root/contrail_packages
    mkdir -p $tmpdir/root/contrail_packages
    aws s3 sync s3://contrailrhel7 $CONTRAIL_PACKAGES_DIR
    latest_ver_rpm=`ls ${CONTRAIL_PACKAGES_DIR}/${build_series}contrail-install* -vr  | grep $CONTRAIL_VERSION | grep $OPENSTACK_VERSION | head -n1`
    cp $CONTRAIL_PACKAGES_DIR/*.tgz $tmpdir/root/contrail_packages/
    cp $latest_ver_rpm $tmpdir/root/contrail_packages/
  fi

  # cp rhel account file
  if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
    local rhel_account_file_dir=$(dirname "$RHEL_ACCOUNT_FILE")
    mkdir -p $tmpdir/$rhel_account_file_dir
    cp $RHEL_ACCOUNT_FILE $tmpdir/$rhel_account_file_dir/
    chmod -R 644 $tmpdir/$rhel_account_file_dir
    chmod +x $tmpdir/$rhel_account_file_dir
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
    --vcpus=2,cores=2 \
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

_patch_image "$pool_path/undercloud-$NUM.qcow2" \
  'ifcfg-ethM' $mgmt_ip $mgmt_mac \
  'ifcfg-ethA' $prov_ip $prov_mac

if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  rhel_register_system_and_customize "$pool_path/undercloud-$NUM.qcow2" 'undercloud'
fi

_start_vm "rd-undercloud-$NUM" "$pool_path/undercloud-$NUM.qcow2" \
  $mgmt_mac $prov_mac

if [[ "$RHEL_CERT_TEST" == 'true' ]] ; then
  _patch_image "$pool_path/undercloud-$NUM-cert-test.qcow2" \
    'ifcfg-ethMC' $mgmt_ip $mgmt_mac_cert \
    'ifcfg-ethAC' $prov_ip $prov_mac_cert \
    'no'

  rhel_register_system_and_customize "$pool_path/undercloud-$NUM-cert-test.qcow2" 'undercloud'

  _start_vm \
    "rd-undercloud-$NUM-cert-test" "$pool_path/undercloud-$NUM-cert-test.qcow2" \
    $mgmt_mac_cert $prov_mac_cert 4096
fi


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

if [[ "$RHEL_CERT_TEST" == 'true' ]] ; then
  _wait_machine "${mgmt_ip}.3"
  _prepare_network "${mgmt_ip}.3"  "myhost.my${NUM}certdomain"

  cat <<EOF | $ssh_cmd ${mgmt_ip}.3
set -x
iptables -I INPUT 1 -p udp -m multiport --dports 8009 -m comment --comment \"rhcertd\" -m state --state NEW -j ACCEPT
iptables -I INPUT 1 -p tcp -m multiport --dports 8009 -m comment --comment \"rhcertd\" -m state --state NEW -j ACCEPT
iptables -I INPUT 1 -p tcp -m multiport --dports 80,443 -m comment --comment \"http_https\" -m state --state NEW -j ACCEPT
yum install -y redhat-certification
systemctl start httpd
rhcertd start
sed -i "s/ALLOWED_HOSTS =.*/ALLOWED_HOSTS = ['myhost.my${NUM}certdomain', '${mgmt_ip}.3', '${prov_ip}.201', 'localhost.localdomain', 'localhost', '127.0.0.1']/" /var/www/rhcert/project/settings.py
systemctl restart httpd
EOF

fi
