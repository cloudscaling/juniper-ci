#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

NUM=${NUM:-0}
DEPLOY=${DEPLOY:-0}
NETWORK_ISOLATION=${NETWORK_ISOLATION:-'single'}

# common setting from create_env.sh
if [[ -z "$NUM" ]] ; then
  echo "Please set NUM variable to specific environment number. (export NUM=4)"
  exit 1
fi

CLOUD_DOMAIN_NAME=${CLOUD_DOMAIN_NAME:-'localdomain'}
SSH_VIRT_TYPE=${VIRT_TYPE:-'virsh'}
BASE_ADDR=${BASE_ADDR:-172}
MEMORY=${MEMORY:-8000}
SWAP=${SWAP:-0}
SSH_USER=${SSH_USER:-'stack'}
CPU_COUNT=${CPU_COUNT:-2}
DISK_SIZE=${DISK_SIZE:-29}

# su - stack
cd ~

if [[ "$(whoami)" != "stack" ]] ; then
  echo "This script must be run under the 'stack' user"
  exit 1
fi

((prov_ip_addr=176+NUM*10))
prov_ip="192.168.${prov_ip_addr}.2"

((addr=BASE_ADDR+NUM*10))
virt_host_ip="192.168.${addr}.1"
if [[ "$SSH_VIRT_TYPE" != 'vbox' ]] ; then
  virsh_opts="-c qemu+ssh://${SSH_USER}@${virt_host_ip}/system"
  list_vm_cmd="virsh $virsh_opts list --all"
else
  ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  ssh_addr="${SSH_USER}@${virt_host_ip}"
  list_vm_cmd="ssh $ssh_opts $ssh_addr /usr/bin/VBoxManage list vms"
fi

CONT_COUNT=$($list_vm_cmd | grep rd-overcloud-$NUM-cont- | wc -l)
COMP_COUNT=$($list_vm_cmd | grep rd-overcloud-$NUM-comp- | wc -l)
CONTRAIL_CONTROLLER_COUNT=$($list_vm_cmd | grep rd-overcloud-$NUM-ctrlcont- | wc -l)
ANALYTICS_COUNT=$($list_vm_cmd | grep rd-overcloud-$NUM-ctrlanalytics- | wc -l)
ANALYTICSDB_COUNT=$($list_vm_cmd | grep rd-overcloud-$NUM-ctrlanalyticsdb- | wc -l)
((OCM_COUNT=CONT_COUNT+COMP_COUNT+CONTRAIL_CONTROLLER_COUNT+ANALYTICS_COUNT+ANALYTICSDB_COUNT))

# collect MAC addresses of overcloud machines
function get_macs() {
  local type=$1
  local count=$2
  truncate -s 0 /tmp/nodes-$type.txt
  for (( i=1; i<=count; i++ )) ; do
    if [[ "$SSH_VIRT_TYPE" != 'vbox' ]] ; then
      virsh $virsh_opts domiflist rd-overcloud-$NUM-$type-$i | awk '$3 ~ "prov" {print $5};'
    else
      ssh $ssh_opts $ssh_addr /usr/bin/VBoxManage showvminfo rd-overcloud-$NUM-$type-$i | awk '/NIC 1/ {print $4}' | cut -d ',' -f 1 | sed 's/\(..\)/\1:/g' | sed 's/:$//'
    fi
  done > /tmp/nodes-$type.txt
  echo "macs for '$type':"
  cat /tmp/nodes-$type.txt
}

get_macs cont $CONT_COUNT
get_macs comp $COMP_COUNT
get_macs ctrlcont $CONTRAIL_CONTROLLER_COUNT
get_macs ctrlanalytics $ANALYTICS_COUNT
get_macs ctrlanalyticsdb $ANALYTICSDB_COUNT

id_rsa=$(awk 1 ORS='\\n' ~/.ssh/id_rsa)
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

define_vms 'cont' $CONT_COUNT 'profile:controller,boot_option:local'
define_vms 'comp' $COMP_COUNT 'profile:compute,boot_option:local'
define_vms 'ctrlcont' $CONTRAIL_CONTROLLER_COUNT 'profile:contrail-controller,boot_option:local'
define_vms 'ctrlanalytics' $ANALYTICS_COUNT 'profile:contrail-analytics,boot_option:local'
define_vms 'ctrlanalyticsdb' $ANALYTICSDB_COUNT 'profile:contrail-analyticsdb,boot_option:local'

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
for id in `openstack flavor list -f value -c ID` ; do openstack flavor delete $id ; done

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
create_flavor 'compute' $COMP_COUNT 'compute'
create_flavor 'contrail-controller' $CONTRAIL_CONTROLLER_COUNT 'contrail-controller'
create_flavor 'contrail-analytics' $ANALYTICS_COUNT 'contrail-analytics'
create_flavor 'contrail-analytics-database' $ANALYTICSDB_COUNT 'contrail-analyticsdb'

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


# prepare Contrail puppet modules via uploading artifacts to swift
rm -rf usr/share/openstack-puppet/modules
mkdir -p usr/share/openstack-puppet/modules
git clone https://github.com/Juniper/contrail-tripleo-puppet -b stable/newton usr/share/openstack-puppet/modules/tripleo
#TODO: replace personal repo with Juniper ones
git clone https://github.com/alexey-mr/puppet-contrail -b stable/newton usr/share/openstack-puppet/modules/contrail
tar czvf puppet-modules.tgz usr/
upload-swift-artifacts -c contrail-artifacts -f puppet-modules.tgz


# prepare tripleo heat templates
rm -rf ~/tripleo-heat-templates
cp -r /usr/share/openstack-tripleo-heat-templates/ ~/tripleo-heat-templates
rm -rf ~/contrail-tripleo-heat-templates
# TODO: replace personal repo with Juniper one
#git clone https://github.com/Juniper/contrail-tripleo-heat-templates -b stable/newton
git clone https://github.com/alexey-mr/contrail-tripleo-heat-templates -b stable/newton
cp -r ~/contrail-tripleo-heat-templates/environments/contrail ~/tripleo-heat-templates/environments
cp -r ~/contrail-tripleo-heat-templates/puppet/services/network/* ~/tripleo-heat-templates/puppet/services/network

role_file='tripleo-heat-templates/environments/contrail/roles_data.yaml'

contrail_services_file='tripleo-heat-templates/environments/contrail/contrail-services.yaml'
sed -i "s/ContrailRepo:.*/ContrailRepo:  http:\/\/${prov_ip}\/contrail/g" $contrail_services_file
sed -i "s/ControllerCount:.*/ControllerCount: $CONT_COUNT/g" $contrail_services_file
sed -i "s/ContrailControllerCount:.*/ContrailControllerCount: $CONTRAIL_CONTROLLER_COUNT/g" $contrail_services_file
sed -i "s/ContrailAnalyticsCount:.*/ContrailAnalyticsCount: $ANALYTICS_COUNT/g" $contrail_services_file
sed -i "s/ContrailAnalyticsDatabaseCount:.*/ContrailAnalyticsDatabaseCount: $ANALYTICSDB_COUNT/g" $contrail_services_file
sed -i "s/ComputeCount:.*/ComputeCount: $COMP_COUNT/g" $contrail_services_file
sed -i 's/NtpServer:.*/NtpServer: 3.europe.pool.ntp.org/g' $contrail_services_file

if [[ $NETWORK_ISOLATION == "single" ]] ; then
  contrail_net_file='tripleo-heat-templates/environments/contrail/contrail-net-single.yaml'
  sed -i "s/ControlPlaneDefaultRoute:.*/ControlPlaneDefaultRoute: ${prov_ip}/g" $contrail_net_file
  sed -i "s/EC2MetadataIp:.*/EC2MetadataIp: ${prov_ip}/g" $contrail_net_file
  sed -i "s/VrouterPhysicalInterface:.*/VrouterPhysicalInterface: ens3/g" $contrail_net_file
  sed -i "s/VrouterGateway:.*/VrouterGateway: ${prov_ip}/g" $contrail_net_file
  sed -i "s/ControlVirtualInterface:.*/ControlVirtualInterface: ens3/g" $contrail_net_file
  sed -i "s/PublicVirtualInterface:.*/PublicVirtualInterface: ens4/g" $contrail_net_file
else
  echo TODO: not implemented
  exit -1
fi

# Create ports for Contrail Controller and/or Analytis if any is installed on own node.
# In that case OS controller will host VIP and haproxy will forward requests.
enable_ext_puppet_syntax='false'
contrail_vip_env='contrail_controller_vip_env.yaml'
  cat <<EOF > $contrail_vip_env
resource_registry:
EOF
if (( CONTRAIL_CONTROLLER_COUNT > 0 )) ; then
  echo INFO: contrail controllers are installed on own nodes, prepare VIPs env file
  contrail_controller_vip='contrail_controller_vip.yaml'
  cat <<EOF > $contrail_controller_vip
heat_template_version: 2016-10-14
parameters:
  ContrailControllerVirtualFixedIPs:
    default: []
    description: Should be used for arbitrary ips.
    type: json
resources:
  Networks:
    type: OS::TripleO::Network
  ContrailControllerVirtualIP:
    type: OS::Neutron::Port
    depends_on: Networks
    properties:
      name: contrail_controller_virtual_ip
      network: {get_param: NeutronControlPlaneID}
      fixed_ips: {get_param: ContrailControllerVirtualFixedIPs}
      replacement_policy: AUTO
outputs:
  ContrailConfigVIP:
    value: {get_attr: [ContrailControllerVirtualIP, fixed_ips, 0, ip_address]}
  ContrailVIP:
    value: {get_attr: [ContrailControllerVirtualIP, fixed_ips, 0, ip_address]}
  ContrailWebuiVIP:
    value: {get_attr: [ContrailControllerVirtualIP, fixed_ips, 0, ip_address]}
EOF
  cat <<EOF >> $contrail_vip_env
  OS::TripleO::ContrailControllerVirtualIPs: $contrail_controller_vip
EOF
else
  echo INFO: contrail controllers are installed on OS controller nodes
  cat <<EOF >> $contrail_vip_env
  OS::TripleO::ContrailAnalyticsVirtualIPs: OS::Heat::None
EOF
  echo INFO: add contrail controller services to OS Controller role
  enable_ext_puppet_syntax='true'
  pos_to_insert=`sed "=" $role_file | sed -n '/^- name: Controller$/,/^  ServicesDefault:/p' | grep -o '^[0-9]\+' | tail -n 1`
  to_add='    - OS::TripleO::Services::ContrailConfig\\n    - OS::TripleO::Services::ContrailControl\\n'
  to_add+='    - OS::TripleO::Services::ContrailDatabase\\n    - OS::TripleO::Services::ContrailWebUI'
  sed -i "${pos_to_insert} a\\$to_add" $role_file
fi
if (( ANALYTICS_COUNT > 0 )) ; then
  echo INFO: contrail analytics are installed on own nodes, prepare VIPs env file
  contrail_analytics_vip='contrail_analytics_vip.yaml'
  cat <<EOF > $contrail_analytics_vip
heat_template_version: 2016-10-14
parameters:
  ContrailAnalyticsVirtualFixedIPs:
    default: []
    description: Should be used for arbitrary ips.
    type: json
resources:
  Networks:
    type: OS::TripleO::Network
  ContrailAnalyticsVirtualIP:
    type: OS::Neutron::Port
    depends_on: Networks
    properties:
      name: contrail_analytics_virtual_ip
      network: {get_param: NeutronControlPlaneID}
      fixed_ips: {get_param: ContrailAnalyticsVirtualFixedIPs}
      replacement_policy: AUTO
outputs:
  ContrailAnalyticsVIP:
    value: {get_attr: [ContrailAnalyticsVirtualIP, fixed_ips, 0, ip_address]}
EOF
  cat <<EOF >> $contrail_vip_env
  OS::TripleO::ContrailAnalyticsVirtualIPs: $contrail_analytics_vip
EOF
else
  echo INFO: contrail analytics are installed on OS controller nodes
  enable_ext_puppet_syntax='true'
  cat <<EOF >> $contrail_vip_env
  OS::TripleO::ContrailAnalyticsVirtualIPs: OS::Heat::None
EOF
  echo INFO: add contrail analytics services to OS Controller role
  pos_to_insert=`sed "=" $role_file | sed -n '/^- name: Controller$/,/^  ServicesDefault:/p' | grep -o '^[0-9]\+' | tail -n 1`
  sed -i "${pos_to_insert} a\\    - OS::TripleO::Services::ContrailAnalytics" $role_file
fi
if (( ANALYTICSDB_COUNT == 0 )) ; then
  echo INFO: add contrail analyticsdb services to OS Controller role
  enable_ext_puppet_syntax='true'
  pos_to_insert=`sed "=" $role_file | sed -n '/^- name: Controller$/,/^  ServicesDefault:/p' | grep -o '^[0-9]\+' | tail -n 1`
  sed -i "${pos_to_insert} a\\    - OS::TripleO::Services::ContrailAnalyticsDatabase" $role_file
fi

# other options
misc_opts='misc_opts.yaml'
rm -f $misc_opts
if [[ "$enable_ext_puppet_syntax" == 'true' ]] ; then
  cat <<EOF > enable_ext_puppet_syntax.yaml
heat_template_version: 2014-10-16
parameters:
  server:
    description: ID of the controller node to apply this config to
    type: string
resources:
  NodeConfig:
    type: OS::Heat::SoftwareConfig
    properties:
      group: script
      config: |
        #!/bin/bash
        sed -i '/\[main\]/a \ \ \ \ \parser = future' /etc/puppet/puppet.conf
  NodeDeployment:
    type: OS::Heat::SoftwareDeployment
    properties:
      config: {get_resource: NodeConfig}
      server: {get_param: server}
outputs:
  deploy_stdout:
    description: Deployment reference, used to trigger post-deploy on changes
    value: {get_attr: [NodeDeployment, deploy_stdout]}
EOF
  cat <<EOF >> $misc_opts
resource_registry:
  OS::TripleO::ControllerExtraConfigPre: enable_ext_puppet_syntax.yaml
EOF
fi
cat <<EOF >> $misc_opts
parameter_defaults:
  CloudDomain: $CLOUD_DOMAIN_NAME
  GlanceBackend: file
  RabbitUserName: contrail
  RabbitPassword: contrail
  ContrailInsecure: true
EOF
# IMPORTANT: The DNS domain used for the hosts should match the dhcp_domain configured in the Undercloud neutron.
if (( CONT_COUNT < 2 )) ; then
  echo "  EnableGalera: false" >> $misc_opts
fi

ha_opts=""
if (( CONT_COUNT > 1 )) ; then
  ha_opts="-e tripleo-heat-templates/environments/puppet-pacemaker.yaml"
fi

if [[ "$DEPLOY" != '1' ]] ; then
  # deploy overcloud. if you do it manually then I recommend to do it in screen.
  echo "openstack overcloud deploy --templates tripleo-heat-templates/ \
      --roles-file $role_file \
      -e .tripleo/environments/deployment-artifacts.yaml \
      -e $contrail_services_file \
      -e $contrail_net_file \
      -e $contrail_vip_env \
      -e $misc_opts \
      $ha_opts"
  echo "Add '-e templates/firstboot/firstboot.yaml' if you use swap"
  exit
fi

# script will handle errors below
set +e

openstack overcloud deploy --templates tripleo-heat-templates/ \
  --roles-file $role_file \
  -e .tripleo/environments/deployment-artifacts.yaml \
  -e $contrail_services_file \
  -e $contrail_net_file \
  -e $contrail_vip_env \
  -e $misc_opts \
  $ha_opts

errors=$?

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