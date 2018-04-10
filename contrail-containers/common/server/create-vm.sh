#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [[ -z "$WORKSPACE" ]] ; then
  echo "WORKSPACE variable is expected"
  exit -1
fi

if [[ -z "$WAY" ]] ; then
  echo "WAY variable is expected: helm/k8s/kolla"
  exit -1
fi

if [[ -z "$NET_ADDR" ]] ; then
  echo "NET_ADDR variable is expected: e.g. 192.168.222.0"
  exit -1
fi

export ENV_FILE="$WORKSPACE/cloudrc"

source "$my_dir/definitions"
source "$my_dir/${ENVIRONMENT_OS}"

if [[ -z "$ENVIRONMENT_OS" ]] ; then
  echo "ENVIRONMENT_OS is expected (e.g. export ENVIRONMENT_OS=centos)"
  exit 1
fi

if [[ -z "$OPENSTACK_VERSION" ]] ; then
  echo "OPENSTACK_VERSION is expected (e.g. export OPENSTACK_VERSION=ocata)"
  exit 1
fi

if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  if [[ -z "$RHEL_ACCOUNT_FILE" ]] ; then
    echo "ERROR: for rhel environemnt the environment variable RHEL_ACCOUNT_FILE is required"
    exit 1
  fi
fi

# base image for VMs
if [[ -n "$ENVIRONMENT_OS_VERSION" ]] ; then
  DEFAULT_BASE_IMAGE_NAME="${ENVIRONMENT_OS}-${ENVIRONMENT_OS_VERSION}.qcow2"
else
  DEFAULT_BASE_IMAGE_NAME="${ENVIRONMENT_OS}.qcow2"
fi
BASE_IMAGE_NAME=${BASE_IMAGE_NAME:-"$DEFAULT_BASE_IMAGE_NAME"}
BASE_IMAGE_POOL=${BASE_IMAGE_POOL:-'images'}

source "$my_dir/../../../common/virsh/functions"

# check previous env
assert_env_exists "${VM_NAME}_build_$i"
for (( i=0; i<${CONT_NODES}; ++i )); do
  assert_env_exists "${VM_NAME}_cont_$i"
done
for (( i=0; i<${COMP_NODES}; ++i )); do
  assert_env_exists "${VM_NAME}_comp_$i"
done

# re-create network
delete_network_dhcp $NET_NAME
create_network_dhcp $NET_NAME $NET_ADDR $BRIDGE_NAME
# second network can be used for vrouter
if [[ -n "$NET_ADDR_VR" ]]; then
  delete_network_dhcp $NET_NAME_VR
  create_network_dhcp $NET_NAME_VR $NET_ADDR_VR $BRIDGE_NAME_VR
fi

# create pool
create_pool $POOL_NAME

function define_node() {
  local vm_name=$1
  local mem=$2
  local mac_octet=$3
  local vol_name="$vm_name.qcow2"
  delete_volume $vol_name $POOL_NAME
  local vol_path=$(create_volume_from $vol_name $POOL_NAME $BASE_IMAGE_NAME $BASE_IMAGE_POOL)
  local net="$NET_NAME/$NET_MAC_PREFIX:$mac_octet"
  if [[ -n "$NET_ADDR_VR" ]]; then
    net="$net,$NET_NAME_VR/$NET_MAC_VR_PREFIX:$mac_octet"
  fi
  define_machine $vm_name $VCPUS $mem $OS_VARIANT $net $vol_path $DISK_SIZE
}

build_vm=0
if [[ $REGISTRY == 'build' ]]; then
  build_vm=1
  node="${VM_NAME}_build"
  define_node "$node" ${BUILD_NODE_MEM} "ff"
  start_vm "$node"
fi
# define last octet of MAC address as 0$i or 1$i (assuming that count of machine is not more than 9)
for (( i=0; i<${CONT_NODES}; ++i )); do
  node="${VM_NAME}_cont_$i"
  define_node "$node" ${CONT_NODE_MEM} "0$i"
  start_vm "$node"
done
for (( i=0; i<${COMP_NODES}; ++i )); do
  node="${VM_NAME}_comp_$i"
  define_node "$node" ${COMP_NODE_MEM} "1$i"
  start_vm "$node"
done

# wait machine and get IP via virsh net-dhcp-leases $NET_NAME
all_nodes_count=$((build_vm + CONT_NODES + COMP_NODES))
_ips=( $(wait_dhcp $NET_NAME $all_nodes_count ) )
if [[ $REGISTRY == 'build' ]]; then
  build_ip=`get_ip_by_mac $NET_NAME $NET_MAC_PREFIX:ff`
fi
# collect controller ips first and compute ips next
declare -a ips ips_cont ips_comp
for (( i=0; i<${CONT_NODES}; ++i )); do
  ip=`get_ip_by_mac $NET_NAME $NET_MAC_PREFIX:0$i`
  ips=( ${ips[@]} $ip )
  ips_cont=( ${ips_cont[@]} $ip )
done
for (( i=0; i<${COMP_NODES}; ++i )); do
  ip=`get_ip_by_mac $NET_NAME $NET_MAC_PREFIX:1$i`
  ips=( ${ips[@]} $ip )
  ips_comp=( ${ips_comp[@]} $ip )
done

if [[ $REGISTRY == 'build' ]]; then
  wait_ssh $build_ip
  cat <<EOF | ssh $SSH_OPTS root@${ip}
mkdir -p $logs_dir
if [[ "$ENVIRONMENT_OS" == 'centos' ]]; then
  yum install -y epel-release &>>$logs_dir/yum.log
  yum install -y mc git wget iptables iproute libxml2-utils &>>$logs_dir/yum.log
elif [[ "$ENVIRONMENT_OS" == 'ubuntu' ]]; then
  apt-get -y update &>>$logs_dir/apt.log
  apt-get install -y --no-install-recommends mc git wget libxml2-utils &>>$logs_dir/apt.log
  mv /etc/os-release /etc/os-release.original
  cat /etc/os-release.original > /etc/os-release
fi
EOF
fi

for ip in ${ips[@]} ; do
  wait_ssh $ip
done

id_rsa="$(cat $HOME/.ssh/id_rsa)"
id_rsa_pub="$(cat $HOME/.ssh/id_rsa.pub)"
# prepare host name
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30"
index=0
for ip in ${ips[@]} ; do
  (( index+=1 ))

  logs_dir='/root/logs'
  if [[ "$SSH_USER" != 'root' ]] ; then
    logs_dir="/home/$SSH_USER/logs"
  fi

  # prepare node: set hostname, fill /etc/hosts, configure ssh, configure second iface if needed, install software, reboot
  cat <<EOF | ssh $SSH_OPTS root@${ip}
hname="node-\$(echo $ip | tr '.' '-')"
echo \$hname > /etc/hostname
hostname \$hname
domainname localdomain
for i in ${ips[@]} ; do
  hname="node-\$(echo \$i | tr '.' '-')"
  echo \$i  \${hname}.localdomain  \${hname} >> /etc/hosts
done

cat <<EOM > /root/.ssh/config
Host *
  StrictHostKeyChecking no
  UserKnownHostsFile=/dev/null
EOM
echo "$id_rsa" > /root/.ssh/id_rsa
chmod 600 /root/.ssh/id_rsa
echo "$id_rsa_pub" > /root/.ssh/id_rsa.pub
chmod 600 /root/.ssh/id_rsa.pub

if [[ "$SSH_USER" != 'root' ]] ; then
  cat <<EOM > /home/$SSH_USER/.ssh/config
Host *
  StrictHostKeyChecking no
  UserKnownHostsFile=/dev/null
EOM
  echo "$id_rsa" > /home/$SSH_USER/.ssh/id_rsa
  chmod 600 /home/$SSH_USER/.ssh/id_rsa
  echo "$id_rsa_pub" > /home/$SSH_USER/.ssh/id_rsa.pub
  chmod 600 /home/$SSH_USER/.ssh/id_rsa.pub
fi

mkdir -p $logs_dir
if [[ "$ENVIRONMENT_OS" == 'centos' ]]; then
  rm -f /etc/sysconfig/network-scripts/ifcfg-eth0
  if [[ -n "$NET_ADDR_VR" ]]; then
    mac_if2=\$(ip link show ens4 | awk '/link/{print \$2}')
    cat <<EOM > /etc/sysconfig/network-scripts/ifcfg-ens4
BOOTPROTO=dhcp
DEVICE=ens4
HWADDR=\$mac_if2
ONBOOT=yes
TYPE=Ethernet
USERCTL=no
DEFROUTE=no
EOM
    ifup ens4
  fi
  yum update -y &>>$logs_dir/yum.log
  yum install -y epel-release &>>$logs_dir/yum.log
  yum install -y mc git wget ntp ntpdate iptables iproute libxml2-utils python2.7 lsof &>>$logs_dir/yum.log
  systemctl disable chronyd.service
  systemctl enable ntpd.service && systemctl start ntpd.service
elif [[ "$ENVIRONMENT_OS" == 'ubuntu' ]]; then
  if [[ -n "$NET_ADDR_VR" ]]; then
    cat <<EOM > /etc/network/interfaces.d/ens4.cfg
auto ens4
iface ens4 inet dhcp
EOM
    ifup ens4
  fi
  apt-get -y update &>>$logs_dir/apt.log
  DEBIAN_FRONTEND=noninteractive apt-get -fy -o Dpkg::Options::="--force-confnew" upgrade &>>$logs_dir/apt.log
  apt-get install -y --no-install-recommends mc git wget ntp ntpdate libxml2-utils python2.7 lsof python-pip linux-image-extra-\$(uname -r) &>>$logs_dir/apt.log
  mv /etc/os-release /etc/os-release.original
  cat /etc/os-release.original > /etc/os-release
fi
pip install pip --upgrade &>>$logs_dir/pip.log
EOF

  # reboot node
  ssh $SSH_OPTS root@${ip} reboot || /bin/true

done

for ip in ${ips[@]} ; do
  wait_ssh $ip
done

# first machine is master for deploy purposes
master_ip=${ips[0]}

# save env file
cat <<EOF >$ENV_FILE
SSH_USER=$SSH_USER
ssh_key_file=/home/jenkins/.ssh/id_rsa

build_ip=$build_ip
master_ip=$master_ip
nodes_ips="${ips[@]}"
nodes_cont_ips="${ips_cont[@]}"
nodes_comp_ips="${ips_comp[@]}"
EOF
