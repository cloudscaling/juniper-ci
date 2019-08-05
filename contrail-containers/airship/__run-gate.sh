#!/bin/bash -eE

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

mkdir -p $my_dir/logs
source "$my_dir/cloudrc"

mkdir -p /root/deploy && cd /root/deploy
git clone https://github.com/OlegBravo/treasuremap
git clone https://opendev.org/airship/pegleg.git airship-pegleg
git clone https://opendev.org/airship/shipyard.git airship-shipyard

sed -i 's/-it/-i/g' airship-pegleg/tools/pegleg.sh

cd ./treasuremap/tools/deployment/aiab

CPU_COUNT=$(grep -c processor /proc/cpuinfo)
RAM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
# Blindly assume that all storage on this VM is under root FS
DISK_SIZE=$(df --output=source,size / | awk '/dev/ {print $2}')
source /etc/os-release
if [[ $CPU_COUNT -lt 4 || $RAM_TOTAL -lt 20000000 || $DISK_SIZE -lt 30000000 || $NAME != "Ubuntu" || $VERSION_ID != "16.04" ]]; then
  echo "Error: minimum VM recommendations are not met. Exiting."
  exit 1
fi
if [[ $(id -u) -ne 0 ]]; then
  echo "Please execute this script as root!"
  exit 1
fi

export TARGET_SITE="aiab"

if [[ ${VROUTER_ON_DEFAULT_IFACE:-'true'} == 'true' ]]; then
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
export SHORT_HOSTNAME=`getent hosts $LOCAL_IP | head -1 | awk '{print $2}' | cut -d '.' -f 1`
hostname $SHORT_HOSTNAME
echo $SHORT_HOSTNAME > /etc/hostname

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

COMMON_CONFIG_FILE="../../../site/$TARGET_SITE/networks/common-addresses.yaml "
if grep -q "10.96.0.10" "/etc/resolv.conf"; then
  echo "INFO: Not changing DNS servers, /etc/resolv.conf already updated."
else
  sed -i "s/8.8.4.4/$DNS_SERVER/" $COMMON_CONFIG_FILE
fi
domain=$(hostname -d)
if [[ -n "$domain" ]] ; then
  sed -i "s/cluster_domain: cluster.local/cluster_domain: $domain/" $COMMON_CONFIG_FILE
fi

#export PEGLEG_IMAGE="quay.io/airshipit/pegleg:1ada48cc360ec52c7ab28b96c28a0c7df8bcee40"
#export PROMENADE_IMAGE="quay.io/airshipit/promenade:77073ddd6f1a445deae741afe53d858ba39f0e76"

common/deploy-airship.sh demo
