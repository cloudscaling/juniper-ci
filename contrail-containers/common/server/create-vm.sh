#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [[ -z "$NUM" ]]; then
  echo "NUM variable is expected"
  exit -1
fi
if [[ -z "$(echo $NUM | grep '^[1-9][0-9]$')" ]]; then
  echo "NUM value must be in range from 10 to 99"
  exit -1
fi
if [[ -z "$WORKSPACE" ]] ; then
  echo "WORKSPACE variable is expected"
  exit -1
fi
if [[ -z "$WAY" ]] ; then
  echo "WAY variable is expected: helm/k8s/kolla"
  exit -1
fi
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
NET_COUNT=${NET_COUNT:-1}
if (( NET_COUNT > 4 )); then
  echo "NET_COUNT more than 4 is not supported"
  exit 1
fi

export ENV_FILE="$WORKSPACE/cloudrc.$NUM"
source "$my_dir/definitions"
source "$my_dir/${ENVIRONMENT_OS}"

trap 'catch_errors_cvmb $LINENO' ERR
function catch_errors_cvmb() {
  local exit_code=$?
  trap - ERR
  echo "Line: $1  Error=$exit_code"
  echo "Command: '$(eval echo \"$BASH_COMMAND\")'"
  exit $exit_code
}

source "$my_dir/../../../common/virsh/functions"

# check previous env
assert_env_exists "${VM_NAME}_build_$i"
for (( i=0; i<${CONT_NODES}; ++i )); do
  assert_env_exists "${VM_NAME}_cont_$i"
done
for (( i=0; i<${COMP_NODES}; ++i )); do
  assert_env_exists "${VM_NAME}_comp_$i"
done

# re-create networks
delete_network_dhcp $NET_NAME
create_network_dhcp $NET_NAME 10.$NET_BASE_PREFIX.$NUM.${NET_GW_OCTET:-1} $BRIDGE_NAME
for ((j=1; j<NET_COUNT; ++j)); do
  delete_network_dhcp ${NET_NAME}_$j
  create_network_dhcp ${NET_NAME}_$j 10.$((NET_BASE_PREFIX+j)).$NUM.${NET_GW_OCTET:-1} ${BRIDGE_NAME}_$j
done

# create pool
create_pool $POOL_NAME

function define_node() {
  local vm_name=$1
  local vcpus=$2
  local mem=$3
  local mac_octet=$4

  local vol_name="$vm_name.qcow2"
  delete_volume $vol_name $POOL_NAME
  local vol_path=$(create_volume_from $vol_name $POOL_NAME $BASE_IMAGE_NAME $BASE_IMAGE_POOL)

  local opt_disks=''
  local index=0
  for ((; index<${#ADDITIONAL_DISKS[*]}; ++index)); do
    local opt_vol_name="$vm_name-$index.qcow2"
    delete_volume $opt_vol_name $POOL_NAME
    local opt_vol_path=$(create_new_volume $opt_vol_name $POOL_NAME $ADDITIONAL_DISK_SIZE)
    opt_disks+=" $opt_vol_path $ADDITIONAL_DISK_SIZE"
  done

  local net="$NET_NAME/52:54:10:${NET_BASE_PREFIX}:${NUM}:$mac_octet"
  for ((j=1; j<NET_COUNT; ++j)); do
    net="$net,${NET_NAME}_$j/52:54:10:$((NET_BASE_PREFIX+j)):${NUM}:$mac_octet"
  done
  define_machine $vm_name $vcpus $mem $OS_VARIANT $net $vol_path $opt_disks
}

function attach_opt_vols() {
  local letters=(b c d e f g h)
  local ip=$1
  local index=0
  for ((; index<${#ADDITIONAL_DISKS[*]}; ++index)); do
    # 98 - char 'b'
    local letter=${letters[index]}
    local path=${ADDITIONAL_DISKS[index]}
    cat <<EOF | ssh $SSH_OPTS root@${ip}
(echo o; echo n; echo p; echo 1; echo ; echo ; echo w) | fdisk /dev/vd${letter}
mkfs.ext4 /dev/vd${letter}1
mkdir -p ${path}
echo '/dev/vd${letter}1  ${path}  auto  defaults,auto  0  0' >> /etc/fstab
mount ${path}
EOF
  done
}

build_vm=0
if [[ $CONTAINER_REGISTRY == 'build' || $CONTAINER_REGISTRY == 'fullbuild' ]]; then
  build_vm=1
  node="${VM_NAME}_build"
  define_node "$node" $BUILD_NODE_VCPUS $BUILD_NODE_MEM "ff"
  start_vm "$node"
fi
# define last octet of MAC address as 0$i or 1$i (assuming that count of machine is not more than 9)
for (( i=0; i<${CONT_NODES}; ++i )); do
  node="${VM_NAME}_cont_$i"
  define_node "$node" $CONT_NODE_VCPUS $CONT_NODE_MEM "0$i"
  start_vm "$node"
done
for (( i=0; i<${COMP_NODES}; ++i )); do
  node="${VM_NAME}_comp_$i"
  define_node "$node" $COMP_NODE_VCPUS $COMP_NODE_MEM "1$i"
  start_vm "$node"
done

# wait machine and get IP via virsh net-dhcp-leases $NET_NAME
all_nodes_count=$((build_vm + CONT_NODES + COMP_NODES))
_ips=( $(wait_dhcp $NET_NAME $all_nodes_count ) )
if [[ $CONTAINER_REGISTRY == 'build' || $CONTAINER_REGISTRY == 'fullbuild' ]]; then
  build_ip=`get_ip_by_mac $NET_NAME 52:54:10:${NET_BASE_PREFIX}:${NUM}:ff`
fi
# collect controller ips first and compute ips next
declare -a ips ips_cont ips_comp
for (( i=0; i<${CONT_NODES}; ++i )); do
  ip=`get_ip_by_mac $NET_NAME 52:54:10:${NET_BASE_PREFIX}:${NUM}:0$i`
  echo "INFO: controller node #$i, IP $ip (network $NET_NAME)"
  ips=( ${ips[@]} $ip )
  ips_cont=( ${ips_cont[@]} $ip )
done
for (( i=0; i<${COMP_NODES}; ++i )); do
  ip=`get_ip_by_mac $NET_NAME 52:54:10:${NET_BASE_PREFIX}:${NUM}:1$i`
  echo "INFO: compute node #$i, IP $ip (network $NET_NAME)"
  ips=( ${ips[@]} $ip )
  ips_comp=( ${ips_comp[@]} $ip )
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

if [[ $CONTAINER_REGISTRY == 'build' || $CONTAINER_REGISTRY == 'fullbuild' ]]; then
  wait_ssh $build_ip
  logs_dir='/root/logs'
  cat <<EOF | ssh $SSH_OPTS root@${build_ip}
mkdir -p $logs_dir
if [[ "$ENVIRONMENT_OS" == 'centos' ]]; then
  yum install -y epel-release &>>$logs_dir/yum.log
  yum install -y mc git wget iptables iproute libxml2-utils &>>$logs_dir/yum.log
elif [[ "$ENVIRONMENT_OS" == 'ubuntu16' || "$ENVIRONMENT_OS" == 'ubuntu18' ]]; then
  apt-get -y update &>>$logs_dir/apt.log
  apt-get install -y --no-install-recommends mc git wget libxml2-utils &>>$logs_dir/apt.log
  mv /etc/os-release /etc/os-release.original
  cat /etc/os-release.original > /etc/os-release
fi
EOF
  attach_opt_vols $build_ip
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
  attach_opt_vols $ip
  cat <<EOF | ssh $SSH_OPTS root@${ip}
hname="node-\$(echo $ip | tr '.' '-')"
echo \$hname > /etc/hostname
hostname \$hname
domainname local
for i in ${ips[@]} ; do
  hname="node-\$(echo \$i | tr '.' '-')"
  echo \$i  \${hname}.local  \${hname} >> /etc/hosts
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
  for ((j=1; j<$NET_COUNT; ++j)); do
    if_name="ens\$((3+j))"
    mac_if=\$(ip link show \${if_name} | awk '/link/{print \$2}')
    cat <<EOM > /etc/sysconfig/network-scripts/ifcfg-\${if_name}
BOOTPROTO=dhcp
DEVICE=\${if_name}
HWADDR=\$mac_if
ONBOOT=yes
TYPE=Ethernet
USERCTL=no
DEFROUTE=no
EOM
    ifup \${if_name}
  done
  yum update -y &>>$logs_dir/yum.log
  yum install -y epel-release &>>$logs_dir/yum.log
  yum install -y mc git wget iptables iproute libxml2-utils python2.7 lsof python-pip python-devel gcc&>>$logs_dir/yum.log
  yum remove -y python-requests cloud-init
elif [[ "$ENVIRONMENT_OS" == 'ubuntu16' || "$ENVIRONMENT_OS" == 'ubuntu18' ]]; then
  apt-get -y update &>>$logs_dir/apt.log
  apt-get -y purge unattended-upgrades &>>$logs_dir/apt.log
  if [[ "$AGENT_MODE" == 'dpdk' ]]; then
    if [[ "$ENVIRONMENT_OS" == 'ubuntu18' ]]; then
      dpdk_req="linux-modules-extra-\$(uname -r)"
    else
      dpdk_req="linux-image-extra-\$(uname -r)"
    fi
  fi
  DEBIAN_FRONTEND=noninteractive apt-get -fy -o Dpkg::Options::="--force-confnew" upgrade &>>$logs_dir/apt.log
  DEBIAN_FRONTEND=noninteractive apt-get -fy -o Dpkg::Options::="--force-confnew" install -y --no-install-recommends mc git wget libxml2-utils python2.7 lsof python-pip python-dev gcc \$dpdk_req &>>$logs_dir/apt.log
  echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  if [[ "$ENVIRONMENT_OS" == 'ubuntu18' ]]; then
    apt-get install ifupdown &>>$logs_dir/apt.log
    echo "source /etc/network/interfaces.d/*" >> /etc/network/interfaces
    mv /etc/netplan/50-cloud-init.yaml /etc/netplan/__50-cloud-init.yaml.save
    if_name="ens\$((3+j))"
    cat <<EOM > /etc/network/interfaces.d/ens3.cfg
auto ens3
iface ens3 inet dhcp
EOM
  fi
  for ((j=1; j<$NET_COUNT; ++j)); do
    if_name="ens\$((3+j))"
    cat <<EOM > /etc/network/interfaces.d/\${if_name}.cfg
auto \${if_name}
iface \${if_name} inet dhcp
EOM
  done
  mv /etc/os-release /etc/os-release.original
  cat /etc/os-release.original > /etc/os-release
fi
pip install pip --upgrade &>>$logs_dir/pip.log
hash -r
pip install setuptools requests &>>$logs_dir/pip.log
if [[ "$ENVIRONMENT_OS" == 'ubuntu18' ]]; then
  rm /etc/resolv.conf
  ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
fi
EOF
done

if [[ "$AGENT_MODE" == 'dpdk' ]]; then
  for ip in ${ips_comp[@]} ; do
    if [[ "$ENVIRONMENT_OS" == 'centos' ]]; then
      ssh $SSH_OPTS root@${ip} "sed -i 's/tty0 /tty0 default_hugepagesz=2M hugepagesz=2M hugepages=2048 /g' /boot/grub2/grub.cfg"
    else
      ssh $SSH_OPTS root@${ip} "sed -i 's/ttyS0/ttyS0 default_hugepagesz=2M hugepagesz=2M hugepages=2048/g' /boot/grub/grub.cfg"
    fi
  done
fi

for ip in ${ips[@]} ; do
  # reboot node
  ssh $SSH_OPTS root@${ip} reboot || /bin/true
done

for ip in ${ips[@]} ; do
  wait_ssh $ip
  while ! ssh $SSH_OPTS root@${ip} "uname -a" 2>/dev/null ; do
    echo "WARNING: Machine ${ip} isn't accessible yet"
    sleep 2
  done
  if [[ "$ENVIRONMENT_OS" == 'ubuntu18' ]]; then
    ssh $SSH_OPTS root@$ip "rm /etc/resolv.conf ; ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf"
  fi
done

echo "nodes_net=10.$NET_BASE_PREFIX.$NUM.0/24" >> $ENV_FILE
echo "nodes_gw=10.$NET_BASE_PREFIX.$NUM.1" >> $ENV_FILE
echo "nodes_vip=10.$NET_BASE_PREFIX.$NUM.254" >> $ENV_FILE

# update env file with IP-s from all interfaces
for ((j=0; j<NET_COUNT; ++j)); do
  declare -a ips ips_cont ips_comp ; ips=() ; ips_cont=() ; ips_comp=()
  for (( i=0; i<${CONT_NODES}; ++i )); do
    ip=`get_ip_by_mac ${NET_NAME}_$j 52:54:10:$((NET_BASE_PREFIX+j)):${NUM}:0$i`
    echo "INFO: controller node #$i, IP $ip (network ${NET_NAME}_$j)"
    ips=( ${ips[@]} $ip )
    ips_cont=( ${ips_cont[@]} $ip )
  done
  for (( i=0; i<${COMP_NODES}; ++i )); do
    ip=`get_ip_by_mac ${NET_NAME}_$j 52:54:10:$((NET_BASE_PREFIX+j)):${NUM}:1$i`
    echo "INFO: compute node #$i, IP $ip (network ${NET_NAME}_$j)"
    ips=( ${ips[@]} $ip )
    ips_comp=( ${ips_comp[@]} $ip )
  done

  for ip in ${ips[@]} ; do
    # post-prepare node: fill /etc/hosts with all other ips
    cat <<EOF | ssh $SSH_OPTS root@${ip}
for i in ${ips[@]} ; do
  hname="node-\$(echo \$i | tr '.' '-')"
  echo \$i  \${hname}.local  \${hname} >> /etc/hosts
done
EOF
  done

  cat <<EOF >>$ENV_FILE
nodes_ips_${j}="${ips[@]}"
nodes_cont_ips_${j}="${ips_cont[@]}"
nodes_comp_ips_${j}="${ips_comp[@]}"
nodes_net_${j}=10.$((NET_BASE_PREFIX+j)).$NUM.0/24
nodes_gw_${j}=10.$((NET_BASE_PREFIX+j)).$NUM.1
nodes_vip_${j}=10.$((NET_BASE_PREFIX+j)).$NUM.254
EOF
done

echo "build_user=${BUILD_USER_ID:-jenkins}" >> $ENV_FILE
echo "INFO: environment file:"
cat $ENV_FILE

# copy environment file to master_ip
$SCP $ENV_FILE root@${master_ip}:cloudrc

trap - ERR
