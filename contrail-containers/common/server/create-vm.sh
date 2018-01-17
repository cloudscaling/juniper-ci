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

VCPUS=4

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

NODES=( "${VM_NAME}_1" "${VM_NAME}_2" "${VM_NAME}_3" "${VM_NAME}_4" )
for i in ${NODES[@]} ; do
  assert_env_exists "$i"
done

# re-create network
delete_network_dhcp $NET_NAME
create_network_dhcp $NET_NAME $NET_ADDR $BRIDGE_NAME

# create pool
create_pool $POOL_NAME

# re-create disk
function define_node() {
  local vm_name=$1
  local mem=$2
  local vol_name="$vm_name.qcow2"
  delete_volume $vol_name $POOL_NAME
  local vol_path=$(create_volume_from $vol_name $POOL_NAME $BASE_IMAGE_NAME $BASE_IMAGE_POOL)
  define_machine $vm_name $VCPUS $mem $OS_VARIANT $NET_NAME $vol_path $DISK_SIZE
}

# First 3 are controllers,
# latest is agent
MEM_MAP=( 16284 16284 16284 4096 )
CTRL_MEM_LIMIT=10000
for (( i=0; i < ${#NODES[@]}; ++i )) ; do
  define_node "${NODES[$i]}" ${MEM_MAP[$i]}
done

# customize domain to set root password
# TODO: access denied under non root...
# customized manually for now
#for i in ${NODES[@]} ; do
#  domain_customize $i ${WAY}.local
#done

# start nodes
for i in ${NODES[@]} ; do
  start_vm $i
done

#wait machine and get IP via virsh net-dhcp-leases $NET_NAME
ips=( $(wait_dhcp $NET_NAME ${#NODES[@]} ) )
for ip in ${ips[@]} ; do
  wait_ssh $ip
done

id_rsa="$(cat ~/.ssh/id_rsa)"
id_rsa_pub="$(cat ~/.ssh/id_rsa.pub)"
# prepare host name
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30"
index=0
for ip in ${ips[@]} ; do
  (( index+=1 ))
  cat <<EOF | ssh $SSH_OPTS root@${ip}
set -x
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

EOF
done


# sort IPs according to MEM, agent machine has less RAM than CTRL_MEM_LIMIT
# put agent machines at the end of list
_ips=( ${ips[@]} )
ips=()
for ip in ${_ips[@]} ; do
  mem=$(ssh $SSH_OPTS root@${ip} free -m | awk '/Mem/ {print $2}')
  if (( mem < CTRL_MEM_LIMIT )) ; then
    ips=( ${ips[@]} $ip )
  else
    ips=( $ip ${ips[@]} )
  fi
done

# first machine is master
master_ip=${ips[0]}

# save env file
cat <<EOF >$ENV_FILE
SSH_USER=$SSH_USER
public_ip=$master_ip
public_ip_build=$master_ip
public_ip_cloud=$master_ip
ssh_key_file=/home/jenkins/.ssh/id_rsa
nodes="${NODES[@]}"
nodes_ips="${ips[@]}"
EOF
