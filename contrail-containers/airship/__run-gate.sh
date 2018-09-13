#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

mkdir -p $my_dir/logs
source "$my_dir/cloudrc"

mkdir -p /root/deploy && cd /root/deploy
git clone https://github.com/openstack/airship-in-a-bottle
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
export NODE_NET_IFACE="ens4"
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

export HOSTIP=$LOCAL_IP
# x/32 will work for CEPH in a single node deploy.
export HOSTCIDR=$LOCAL_IP/32

# Changes DNS servers in common-addresses.yaml to the system's DNS servers
get_dns_servers ()
{
  if hash nmcli 2>/dev/null; then
    nmcli dev show | awk '/IP4.DNS/ {print $2}' | xargs
  else
    cat /etc/resolv.conf | awk '/nameserver/ {print $2}' | xargs
  fi
}

if grep -q "10.96.0.10" "/etc/resolv.conf"; then
  echo "INFO: Not changing DNS servers, /etc/resolv.conf already updated."
else
  DNS_CONFIG_FILE="../../deployment_files/site/$TARGET_SITE/networks/common-addresses.yaml"
  declare -a DNS_SERVERS=($(get_dns_servers))
  NS1=${DNS_SERVERS[0]:-8.8.8.8}
  NS2=${DNS_SERVERS[1]:-$NS1}
  echo "Using DNS servers $NS1 and $NS2."
  sed -i "s/8.8.8.8/$NS1/" $DNS_CONFIG_FILE
  sed -i "s/8.8.4.4/$NS2/" $DNS_CONFIG_FILE
fi

../common/deploy-airship.sh demo
