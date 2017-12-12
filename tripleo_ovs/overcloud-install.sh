#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [[ -z "$NUM" ]] ; then
  echo "Please set NUM variable to specific environment wber. (export NUM=4)"
  exit 1
fi

if [[ -z "$OPENSTACK_VERSION" ]] ; then
  echo "OPENSTACK_VERSION is expected (e.g. export OPENSTACK_VERSION=newton)"
  exit 1
fi

if [[ -z "$MGMT_IP" ]] ; then
  echo "MGMT_IP is expected"
  exit 1
fi

if [[ -z "$PROV_IP" ]] ; then
  echo "PROV_IP is expected"
  exit 1
fi

if [[ -z "$DVR" ]] ; then
  echo "DVR is expected"
  exit 1
fi

DEPLOY=${DEPLOY:-0}
NETWORK_ISOLATION=${NETWORK_ISOLATION:-'single'}

# common setting from create_env.sh
if [[ -z "$NUM" ]] ; then
  echo "Please set NUM variable to specific environment number. (export NUM=4)"
  exit 1
fi

CLOUD_DOMAIN_NAME=${CLOUD_DOMAIN_NAME:-'localdomain'}
SSH_VIRT_TYPE=${VIRT_TYPE:-'virsh'}
MEMORY=${MEMORY:-1000}
SWAP=${SWAP:-0}
SSH_USER=${SSH_USER:-'stack'}
CPU_COUNT=${CPU_COUNT:-2}
DISK_SIZE=${DISK_SIZE:-29}

compute_machine_name='comp'
compute_flavor_name='compute'
storage_flavor_name='storage'
network_flavor_name='network'

# su - stack
cd ~

if [[ "$(whoami)" != "stack" ]] ; then
  echo "This script must be run under the 'stack' user"
  exit 1
fi

prov_ip="$PROV_IP"

virt_host_ip="$(echo $MGMT_IP | cut -d '.' -f 1,2,3).1"
if [[ "$SSH_VIRT_TYPE" != 'vbox' ]] ; then
  virsh_opts="-c qemu+ssh://${SSH_USER}@${virt_host_ip}/system"
  list_vm_cmd="virsh $virsh_opts list --all"
else
  ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  ssh_addr="${SSH_USER}@${virt_host_ip}"
  list_vm_cmd="ssh $ssh_opts $ssh_addr /usr/bin/VBoxManage list vms"
fi

CONT_COUNT=$($list_vm_cmd | grep e$NUM-overcloud-cont- | wc -l)
COMP_COUNT=$($list_vm_cmd | grep e$NUM-overcloud-$compute_machine_name- | wc -l)
STOR_COUNT=$($list_vm_cmd | grep e$NUM-overcloud-stor- | wc -l)
NET_COUNT=$($list_vm_cmd | grep e$NUM-overcloud-net- | wc -l)
((OCM_COUNT=CONT_COUNT+COMP_COUNT+STOR_COUNT+NET_COUNT))

comp_scale_count=$COMP_COUNT

# collect MAC addresses of overcloud machines
function get_macs() {
  local type=$1
  local count=$2
  truncate -s 0 /tmp/nodes-$type.txt
  for (( i=1; i<=count; i++ )) ; do
    if [[ "$SSH_VIRT_TYPE" != 'vbox' ]] ; then
      virsh $virsh_opts domiflist e$NUM-overcloud-$type-$i | awk '$3 ~ "prov" {print $5};'
    else
      ssh $ssh_opts $ssh_addr /usr/bin/VBoxManage showvminfo e$NUM-overcloud-$type-$i | awk '/NIC 1/ {print $4}' | cut -d ',' -f 1 | sed 's/\(..\)/\1:/g' | sed 's/:$//'
    fi
  done > /tmp/nodes-$type.txt
  echo "macs for '$type':"
  cat /tmp/nodes-$type.txt
}

get_macs cont $CONT_COUNT
get_macs $compute_machine_name $COMP_COUNT
get_macs stor $STOR_COUNT
get_macs net $NET_COUNT

id_rsa=$(awk 1 ORS='\\n' ~/.ssh/id_rsa)

function define_machine() {
  local caps=$1
  local mac=$2
  cat << EOF >> ~/instackenv.json
    {
      "pm_addr": "$virt_host_ip",
      "pm_user": "$SSH_USER",
      "pm_password": "$id_rsa",
      "pm_type": "pxe_ssh",
      "ssh_virt_type": "$SSH_VIRT_TYPE",
      "vbox_use_headless": "True",
      "mac": [
        "$mac"
      ],
      "cpu": "$CPU_COUNT",
      "memory": "$MEMORY",
      "disk": "$DISK_SIZE",
      "arch": "x86_64",
      "capabilities": "$caps"
    },
EOF
}

function define_vms() {
  local name=$1
  local count=$2
  local caps=$3
  local mac=''
  for (( i=1; i<=count; i++ )) ; do
    mac=$(sed -n ${i}p /tmp/nodes-${name}.txt)
    define_machine $caps $mac
  done
}

# create overcloud machines definition
cat << EOF > ~/instackenv.json
{
  "ssh-user": "$SSH_USER",
  "ssh-key": "$id_rsa",
  "host-ip": "$virt_host_ip",
  "power_manager": "nova.virt.baremetal.virtual_power_driver.VirtualPowerManager",
  "arch": "x86_64",
  "nodes": [
EOF
define_vms 'cont' $CONT_COUNT 'profile:controller,boot_option:local'
define_vms $compute_machine_name $COMP_COUNT "profile:$compute_flavor_name,boot_option:local"
define_vms 'stor' $STOR_COUNT "profile:$storage_flavor_name,boot_option:local"
define_vms 'net' $NET_COUNT "profile:$network_flavor_name,boot_option:local"

# remove last comma
head -n -1 ~/instackenv.json > ~/instackenv.json.tmp
mv ~/instackenv.json.tmp ~/instackenv.json
cat << EOF >> ~/instackenv.json
    }
  ]
}
EOF

# check this json (it's optional)
if [[ "$DEPLOY" != 1 ]] ; then
  curl --silent -O https://raw.githubusercontent.com/rthallisey/clapper/master/instackenv-validator.py
  python instackenv-validator.py -f instackenv.json
fi

source ~/stackrc

# re-define flavors
for id in `openstack flavor list -f value -c ID` ; do
  openstack flavor delete $id
done

swap_opts=''
if [[ $SWAP != 0 ]] ; then
  swap_opts="--swap $SWAP"
fi

function create_flavor() {
  local name=$1
  local count=$2
  local profile=${3:-''}
  if (( count > 0 )) ; then
    openstack flavor create --id auto --ram $MEMORY $swap_opts --disk $DISK_SIZE --vcpus $CPU_COUNT $name
    openstack flavor set --property "cpu_arch"="x86_64" --property "capabilities:boot_option"="local" $name
    if [[ -n "$profile" ]] ; then
      openstack flavor set --property "capabilities:profile"="${profile}" $name
    else
      echo "Skip flavor profile propery set for $name"
    fi
  else
    echo "Skip flavor creation for $name, count=$count"
  fi
}
create_flavor 'baremetal' 1
create_flavor 'control' $CONT_COUNT 'controller'
create_flavor $compute_flavor_name $COMP_COUNT $compute_flavor_name
create_flavor $storage_flavor_name $STOR_COUNT $storage_flavor_name
create_flavor $network_flavor_name $NET_COUNT $network_flavor_name

openstack flavor list --long

# import overcloud configuration
openstack baremetal import --json ~/instackenv.json
openstack baremetal list
# and configure overcloud
openstack baremetal configure boot

# do introspection - ironic will collect some hardware information from overcloud machines
openstack baremetal introspection bulk start
# this is a recommended command to check and wait end of introspection. but previous command can wait itself.
#sudo journalctl -l -u openstack-ironic-discoverd -u openstack-ironic-discoverd-dnsmasq -u openstack-ironic-conductor -f

rm -rf ~/tripleo-heat-templates
cp -r /usr/share/openstack-tripleo-heat-templates/ ~/tripleo-heat-templates

role_file='tripleo-heat-templates/roles_data.yaml'

# add Network role
cat <<EOF >> $role_file
- name: Network
  CountDefault: 0
  HostnameFormatDefault: '%stackname%-network-%index%'
  disable_upgrade_deployment: True
  ServicesDefault:
    - OS::TripleO::Services::CACerts
    - OS::TripleO::Services::Timezone
    - OS::TripleO::Services::Ntp
    - OS::TripleO::Services::Snmp
    - OS::TripleO::Services::Sshd
    - OS::TripleO::Services::Kernel
    - OS::TripleO::Services::TripleoPackages
    - OS::TripleO::Services::NeutronDhcpAgent
    - OS::TripleO::Services::NeutronL3Agent
    - OS::TripleO::Services::NeutronMetadataAgent
    - OS::TripleO::Services::NeutronOvsAgent
    # - OS::TripleO::Services::ComputeNeutronCorePlugin
    # - OS::TripleO::Services::ComputeNeutronOvsAgent
    # - OS::TripleO::Services::ComputeNeutronL3Agent
    # - OS::TripleO::Services::ComputeNeutronMetadataAgent
    - OS::TripleO::Services::Keepalived
    - OS::TripleO::Services::SensuClient
    - OS::TripleO::Services::FluentdClient
    - OS::TripleO::Services::AuditD
    - OS::TripleO::Services::Collectd
EOF

# disable ceilometer
# there is the bug with 'ceilometer-upgrade --skipt-metering-database'
# https://bugs.launchpad.net/tripleo/+bug/1693339
# wich cause the deployement fails
sed -i  's/\(.*Ceilometer.*\)/#\1/g' $role_file

# file for other options
misc_opts='misc_opts.yaml'

cat <<EOF > $misc_opts
parameter_defaults:
  CloudDomain: $CLOUD_DOMAIN_NAME

  DnsServers: ["8.8.8.8","8.8.4.4"]
  NtpServer: 3.europe.pool.ntp.org

  EC2MetadataIp: ${prov_ip}
  ControlPlaneDefaultRoute: ${prov_ip}

  PublicVirtualInterface: ens3
  ControlVirtualInterface: ens3

  ControllerCount: $CONT_COUNT
  ComputeCount: $COMP_COUNT
  StorageCount: $STOR_COUNT
  NetworkCount: $NET_COUNT

  OvercloudCephStorageFlavor: storage
  CephPoolDefaultSize: 1
EOF


if  (( STOR_COUNT == 0 )) ; then
  GlanceBackend: file
  GnocchiBackend: file
else
  ceph_opts="-e tripleo-heat-templates/environments/storage-environment.yaml"
cat <<EOF > $misc_opts
  CephStorageCount: $STOR_COUNT
  CephClusterFSID: '4b5c8c0a-ff60-454b-a1b4-9747aa737d19'
  CephMonKey: 'AQC+Ox1VmEr3BxAALZejqeHj50Nj6wJDvs96OQ=='
  CephAdminKey: 'AQDLOh1VgEp6FRAAFzT7Zw+Y9V6JJExQAsRnRQ=='
  CephClientKey: 'AQC+vYNXgDAgAhAAc8UoYt+OTz5uhV7ItLdwUw=='
EOF
fi

dvr_opts=''
if [[ "$DVR" == 'true' ]] ; then
  cat <<EOF > dvr_types.yaml
resource_registry:
  OS::TripleO::Controller::Net::SoftwareConfig: tripleo-heat-templates/net-config-bridge.yaml
  OS::TripleO::Compute::Ports::ExternalPort: tripleo-heat-templates/network/ports/external.yaml

parameter_defaults:
  NovaReservedHostMemory: 500
EOF

  # With DVR enabled, the Compute nodes also need the br-ex bridge to be
  # connected to a physical network.
  dvr_opts='-e dvr_types.yaml -e tripleo-heat-templates/environments/neutron-ovs-dvr.yaml'
fi

# IMPORTANT: The DNS domain used for the hosts should match the dhcp_domain configured in the Undercloud neutron.
if (( CONT_COUNT < 2 )) ; then
  echo "  EnableGalera: false" >> $misc_opts
fi

multi_nic_opts=''
if [[ "$use_multi_nic" == 'yes' ]] ; then
  multi_nic_opts+=' -e tripleo-heat-templates/environments/network-management.yaml'
  multi_nic_opts+=' -e tripleo-heat-templates/environments/network-isolation.yaml'
fi

ha_opts=''
if (( CONT_COUNT > 1 )) ; then
  ha_opts="-e tripleo-heat-templates/environments/puppet-pacemaker.yaml"
fi

if [[ "$DEPLOY" != '1' ]] ; then
  # deploy overcloud. if you do it manually then I recommend to do it in screen.
  echo "openstack overcloud deploy --templates tripleo-heat-templates/ \
      --roles-file $role_file \
      $ceph_opts \
      $artifact_opts \
      $dvr_opts \
      -e $misc_opts \
      $multi_nic_opts \
      $ha_opts"
  echo "Add '-e templates/firstboot/firstboot.yaml' if you use swap"
  exit
fi

# script will handle errors below
set +e

openstack overcloud deploy --templates tripleo-heat-templates/ \
  --roles-file $role_file \
  -e tripleo-heat-templates/environments/puppet-ceph.yaml \
  $artifact_opts \
  $dvr_opts \
  -e $misc_opts \
  $multi_nic_opts \
  $ha_opts

errors=$?


echo "INFO: overcloud nodes"
overcloud_nodes=$(openstack server list)
echo "$overcloud_nodes"

echo "INFO: collecting HEAT logs"

echo "INFO: Heat logs" > heat.log
heat stack-list -n >> heat.log
for id in `heat deployment-list | awk '/FAILED/{print $2}'` ; do
  echo "ERROR: Failed deployment $id" >> heat.log
  heat deployment-show $id | grep -vP "stdout|stderr" >> heat.log
  echo "ERROR: stdout" >> heat.log
  heat deployment-output-show $id deploy_stdout >> heat.log
  echo "ERROR: stderr" >> heat.log
  heat deployment-output-show $id deploy_stderr >> heat.log
  ((++errors))
done

for id in `heat resource-list -n 10 overcloud | awk '/FAILED/{print $12"+"$2}'` ; do
  sn="`echo $id | cut -d '+' -f 1`"
  rn="`echo $id | cut -d '+' -f 2`"
  echo "ERROR: Failed resource $sn  $rn" >> heat.log
  heat resource-show $sn $rn >> heat.log
  ((++errors))
done

for id in `heat stack-list | awk '/FAILED/{print $2}'` ; do
  echo "ERROR: Failed stack $id" >> heat.log
  heat stack-show $id >> heat.log
  ((++errors))
done

if (( errors > 0 )) ; then
  exit 1
fi
