#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

mkdir -p $my_dir/logs
source "$my_dir/cloudrc"

mkdir -p /root/deploy && cd /root/deploy
git clone https://github.com/progmaticlab/airship-in-a-bottle
git clone https://git.openstack.org/openstack/airship-pegleg.git
git clone https://git.openstack.org/openstack/airship-shipyard.git

sed -i 's/-it/-i/g' airship-pegleg/tools/pegleg.sh

cd ./airship-in-a-bottle/manifests/dev_single_node

echo "INFO: The minimum recommended size of the Ubuntu 16.04 VM is 4 vCPUs, 20GB of RAM with 32GB disk space. $(date)"
CPU_COUNT=$(grep -c processor /proc/cpuinfo)
RAM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
source /etc/os-release
if [[ $CPU_COUNT -lt 4 || $RAM_TOTAL -lt 20000000 || $NAME != "Ubuntu" || $VERSION_ID != "16.04" ]]; then
  echo "ERROR: minimum VM recommendations are not met. Exiting."
  exit 1
fi
if [[ $(id -u) -ne 0 ]]; then
  echo "ERROR: Please execute this script as root!"
  exit 1
fi

export TARGET_SITE="demo"

if [[ ${VROUTER_ON_DEFAULT_IFACE:-'True'} == 'False' ]]; then
  export NODE_NET_IFACE="ens3"
  export NODE_NET_IFACE_GATEWAY_IP="$nodes_gw"
  export NODE_SUBNETS="$nodes_net"
  export DNS_SERVER="$nodes_gw"
else
  export NODE_NET_IFACE="ens4"
  export NODE_NET_IFACE_GATEWAY_IP="$nodes_gw_1"
  export NODE_SUBNETS="$nodes_net_1"
  export DNS_SERVER="$nodes_gw_1"
fi

LOCAL_IP=`ip addr show ${NODE_NET_IFACE} | awk '/inet /{print $2}' | cut -d '/' -f 1`
export SHORT_HOSTNAME=$(hostname -s)

# Updates the /etc/hosts file
HOSTS="${LOCAL_IP} ${SHORT_HOSTNAME}"
HOSTS_REGEX="${LOCAL_IP}.*${SHORT_HOSTNAME}"
if grep -q "$HOSTS_REGEX" "/etc/hosts"; then
  echo "INFO: Not updating /etc/hosts, entry ${HOSTS} already exists."
else
  echo "INFO: Updating /etc/hosts with: ${HOSTS}"
  cat << EOF | tee -a /etc/hosts
$HOSTS
EOF
fi
chmod 400 /etc/hosts

export HOSTIP=$LOCAL_IP
# x/32 will work for CEPH in a single node deploy.
export HOSTCIDR=$LOCAL_IP/32

if grep -q "10.96.0.10" "/etc/resolv.conf"; then
  echo "INFO: Not changing DNS servers, /etc/resolv.conf already updated."
else
  DNS_CONFIG_FILE="../../deployment_files/site/$TARGET_SITE/networks/common-addresses.yaml"
  sed -i "s/8.8.4.4/$DNS_SERVER/" $DNS_CONFIG_FILE
fi

export PEGLEG_IMAGE="quay.io/airshipit/pegleg:1ada48cc360ec52c7ab28b96c28a0c7df8bcee40"
export PROMENADE_IMAGE="quay.io/airshipit/promenade:77073ddd6f1a445deae741afe53d858ba39f0e76"

../common/deploy-airship.sh demo
