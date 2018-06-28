#!/bin/bash -e

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

export ENV_FILE="$WORKSPACE/cloudrc"
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
create_network_dhcp $NET_NAME 10.$NET_BASE_PREFIX.$JOB_RND.0 $BRIDGE_NAME
for ((j=1; j<NET_COUNT; ++j)); do
  delete_network_dhcp ${NET_NAME}_$j
  create_network_dhcp ${NET_NAME}_$j 10.$((NET_BASE_PREFIX+j)).$JOB_RND.0 ${BRIDGE_NAME}_$j
done

# create pool
create_pool $POOL_NAME

function define_node() {
  local vm_name=$1
  local mem=$2
  local mac_octet=$3
  local vol_name="$vm_name.qcow2"
  delete_volume $vol_name $POOL_NAME
  local vol_path=$(create_volume_from $vol_name $POOL_NAME $BASE_IMAGE_NAME $BASE_IMAGE_POOL)
  local net="$NET_NAME/52:54:10:${NET_BASE_PREFIX}:${JOB_RND}:$mac_octet"
  for ((j=1; j<NET_COUNT; ++j)); do
    net="$net,${NET_NAME}_$j/52:54:10:$((NET_BASE_PREFIX+j)):${JOB_RND}:$mac_octet"
  done
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
  build_ip=`get_ip_by_mac $NET_NAME 52:54:10:${NET_BASE_PREFIX}:${JOB_RND}:ff`
fi
# collect controller ips first and compute ips next
declare -a ips ips_cont ips_comp
for (( i=0; i<${CONT_NODES}; ++i )); do
  ip=`get_ip_by_mac $NET_NAME 52:54:10:${NET_BASE_PREFIX}:${JOB_RND}:0$i`
  echo "INFO: controller node #$i, IP $ip (network $NET_NAME)"
  ips=( ${ips[@]} $ip )
  ips_cont=( ${ips_cont[@]} $ip )
done
for (( i=0; i<${COMP_NODES}; ++i )); do
  ip=`get_ip_by_mac $NET_NAME 52:54:10:${NET_BASE_PREFIX}:${JOB_RND}:1$i`
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

if [[ $REGISTRY == 'build' ]]; then
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
  yum install -y mc git wget ntp ntpdate iptables iproute libxml2-utils python2.7 lsof python-pip python-devel gcc&>>$logs_dir/yum.log
  yum remove -y python-requests cloud-init
  systemctl disable chronyd.service
  systemctl enable ntpd.service && systemctl start ntpd.service
elif [[ "$ENVIRONMENT_OS" == 'ubuntu16' || "$ENVIRONMENT_OS" == 'ubuntu18' ]]; then
  echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  for ((j=1; j<$NET_COUNT; ++j)); do
    if_name="ens\$((3+j))"
    if [[ "$ENVIRONMENT_OS" == 'ubuntu16' ]]; then
      cat <<EOM > /etc/network/interfaces.d/\${if_name}.cfg
auto \${if_name}
iface \${if_name} inet dhcp
EOM
      ifup \${if_name}
    else
      mac_if=\$(ip link show \${if_name} | awk '/link/{print \$2}')
      echo "INFO: create if script for iface=\$if_name with mac=\$mac_if"
      if_path="/etc/netplan/50-cloud-init.yaml"
      cat <<EOM >>"/etc/netplan/50-cloud-init.yaml"
        \$if_name:
            dhcp4: true
            match:
                macaddress: '\$mac_if'
            set-name: \$if_name
EOM
      netplan apply
    fi
  done
  apt-get -y update &>>$logs_dir/apt.log
  if [[ "$ENVIRONMENT_OS" == 'ubuntu18' ]]; then
    dpdk_req="linux-modules-extra-\$(uname -r)"
  else
    dpdk_req="linux-image-extra-\$(uname -r)"
  fi
  DEBIAN_FRONTEND=noninteractive apt-get -fy -o Dpkg::Options::="--force-confnew" upgrade &>>$logs_dir/apt.log
  DEBIAN_FRONTEND=noninteractive apt-get -fy -o Dpkg::Options::="--force-confnew" install -y --no-install-recommends mc git wget ntp ntpdate libxml2-utils python2.7 lsof python-pip python-dev gcc \$dpdk_req &>>$logs_dir/apt.log
  mv /etc/os-release /etc/os-release.original
  cat /etc/os-release.original > /etc/os-release
fi
pip install pip --upgrade &>>$logs_dir/pip.log
hash -r
pip install setuptools &>>$logs_dir/pip.log
EOF

  # reboot node
  ssh $SSH_OPTS root@${ip} reboot || /bin/true

done

for ip in ${ips[@]} ; do
  wait_ssh $ip
  if [[ "$ENVIRONMENT_OS" == 'ubuntu18' ]]; then
    ssh $SSH_OPTS root@${build_ip} systemctl start ntp.service
  fi
done

# update env file with IP-s from other interfaces
for ((j=1; j<NET_COUNT; ++j)); do
  declare -a ips ips_cont ips_comp ; ips=() ; ips_cont=() ; ips_comp=()
  for (( i=0; i<${CONT_NODES}; ++i )); do
    ip=`get_ip_by_mac ${NET_NAME}_$j 52:54:10:$((NET_BASE_PREFIX+j)):${JOB_RND}:0$i`
    echo "INFO: controller node #$i, IP $ip (network ${NET_NAME}_$j)"
    ips=( ${ips[@]} $ip )
    ips_cont=( ${ips_cont[@]} $ip )
  done
  for (( i=0; i<${COMP_NODES}; ++i )); do
    ip=`get_ip_by_mac ${NET_NAME}_$j 52:54:10:$((NET_BASE_PREFIX+j)):${JOB_RND}:1$i`
    echo "INFO: compute node #$i, IP $ip (network ${NET_NAME}_$j)"
    ips=( ${ips[@]} $ip )
    ips_comp=( ${ips_comp[@]} $ip )
  done

  cat <<EOF >>$ENV_FILE
nodes_ips_${j}="${ips[@]}"
nodes_cont_ips_${j}="${ips_cont[@]}"
nodes_comp_ips_${j}="${ips_comp[@]}"
EOF
done

echo "INFO: environment file:"
cat $ENV_FILE

trap - ERR
