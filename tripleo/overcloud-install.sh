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

# TODO: export to job settings
export CONTRAIL_REGISTRY=${CONTRAIL_REGISTRY:-'opencontrailnightly'}
export CONTRAIL_TAG=${CONTRAIL_TAG:-'latest'}
# --

export CCB_PATCHSET=${CCB_PATCHSET-}
export THT_PATCHSET=${THT_PATCHSET:-}
export TPP_PATCHSET=${TPP_PATCHSET:-}
export PP_PATCHSET=${PP_PATCHSET:-}

(( VBMC_PORT_BASE_DEFAULT=16000 + NUM*100))
VBMC_PORT_BASE=${VBMC_PORT_BASE:-${VBMC_PORT_BASE_DEFAULT}}

if [[ -z "$DPDK" ]] ; then
  echo "DPDK is expected"
  exit 1
fi

if [[ -z "$TSN" ]] ; then
  echo "TSN is expected (e.g. export TSN=true/false)"
  exit 1
fi

if [[ -z "$SRIOV" ]] ; then
  echo "SRIOV is expected (e.g. export SRIOV=true/false)"
  exit 1
fi

if [[ -z "$AAA_MODE" ]] ; then
  echo "AAA_MODE is expected (e.g. export AAA_MODE=rbac/cloud-admin/no-auth)"
  exit 1
fi

if [[ -z "$AAA_MODE_ANALYTICS" ]] ; then
  echo "AAA_MODE_ANALYTICS is expected (e.g. export AAA_MODE_ANALYTICS=rbac/cloud-admin/no-auth)"
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
BASE_ADDR=${BASE_ADDR:-172}
MEMORY=${MEMORY:-1000}
SWAP=${SWAP:-0}
SSH_USER=${SSH_USER:-'stack'}
CPU_COUNT=${CPU_COUNT:-2}
DISK_SIZE=${DISK_SIZE:-29}

IPMI_USER=${IPMI_USER:-'stack'}
IPMI_PASSWORD=${IPMI_PASSWORD:-'qwe123QWE'}

if [[ "$DPDK" != 'off' ]] ; then
  compute_machine_name='compdpdk'
  compute_flavor_name='compute-dpdk'
elif [[ "$TSN" == 'true' ]] ; then
  compute_machine_name='comptsn'
  compute_flavor_name='contrail-tsn'
else
  compute_machine_name='comp'
  compute_flavor_name='compute'
fi

# su - stack
cd ~

if [[ "$(whoami)" != "stack" ]] ; then
  echo "This script must be run under the 'stack' user"
  exit 1
fi

((prov_ip_addr=176+NUM*10))
((mgmt_ip_addr=172+NUM*10))
prov_ip="192.168.${prov_ip_addr}.2"
mgmt_ip="192.168.${mgmt_ip_addr}.2"
fixed_ip_base="192.168.${prov_ip_addr}"
fixed_vip="${fixed_ip_base}.200"
fixed_controller_ip="${fixed_ip_base}.211"
ipa_ip="192.168.${prov_ip_addr}.4"


((addr=BASE_ADDR+NUM*10))
virt_host_ip="192.168.${addr}.1"
pm_type="pxe_ipmitool"
export LIBVIRT_DEFAULT_URI="qemu+ssh://${SSH_USER}@${virt_host_ip}/system"

CONT_COUNT=$(virsh list --all | grep rd-overcloud-$NUM-cont- | wc -l)
COMP_COUNT=$(virsh list --all | grep rd-overcloud-$NUM-$compute_machine_name- | wc -l)
CONTRAIL_CONTROLLER_COUNT=$(virsh list --all | grep rd-overcloud-$NUM-ctrlcont- | wc -l)
ANALYTICS_COUNT=$(virsh list --all | grep rd-overcloud-$NUM-ctrlanalytics- | wc -l)
ANALYTICSDB_COUNT=$(virsh list --all | grep rd-overcloud-$NUM-ctrlanalyticsdb- | wc -l)
CONTRAIL_ISSU_COUNT=$(virsh list --all | grep rd-overcloud-$NUM-issu- | wc -l)
((OCM_COUNT=CONT_COUNT+COMP_COUNT+CONTRAIL_CONTROLLER_COUNT+ANALYTICS_COUNT+ANALYTICSDB_COUNT+CONTRAIL_ISSU_COUNT))

if [[ "$DPDK" != 'off' ]] ; then
  comp_scale_count=0
  dpdk_scale_count=$COMP_COUNT
  tsn_scale_count=0
elif [[ "$TSN" == 'true' ]] ; then
  comp_scale_count=0
  dpdk_scale_count=0
  tsn_scale_count=$COMP_COUNT
else
  comp_scale_count=$COMP_COUNT
  dpdk_scale_count=0
  tsn_scale_count=0
fi

# collect MAC addresses of overcloud machines
function get_macs() {
  local type=$1
  local count=$2
  truncate -s 0 /tmp/nodes-$type.txt
  for (( i=1; i<=count; i++ )) ; do
    virsh $virsh_opts domiflist rd-overcloud-$NUM-$type-$i | awk '$3 ~ "prov" {print $5};'
  done > /tmp/nodes-$type.txt
  echo "macs for '$type':"
  cat /tmp/nodes-$type.txt
}

get_macs cont $CONT_COUNT
get_macs $compute_machine_name $COMP_COUNT
get_macs ctrlcont $CONTRAIL_CONTROLLER_COUNT
get_macs ctrlanalytics $ANALYTICS_COUNT
get_macs ctrlanalyticsdb $ANALYTICSDB_COUNT
get_macs issu $CONTRAIL_ISSU_COUNT

function define_machine() {
  local caps=$1
  local mac=$2
  local pm_port=$3
  cat << EOF >> ~/instackenv.json
    {
      "pm_type": "$pm_type",
      "pm_addr": "$virt_host_ip",
      "pm_port": "$pm_port",
      "pm_user": "$IPMI_USER",
      "pm_password": "$IPMI_PASSWORD",
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
  local pm_port=$4
  local mac=''
  for (( i=1; i<=count; i++ )) ; do
    mac=$(sed -n ${i}p /tmp/nodes-${name}.txt)
    define_machine $caps $mac $pm_port
    (( pm_port+= 1 ))
  done
}

# create overcloud machines definition
cat << EOF > ~/instackenv.json
{
  "power_manager": "nova.virt.baremetal.virtual_power_driver.VirtualPowerManager",
  "arch": "x86_64",
  "nodes": [
EOF

vbmc_port=${VBMC_PORT_BASE}
define_vms 'cont' $CONT_COUNT 'profile:controller,boot_option:local' $vbmc_port
(( vbmc_port+=CONT_COUNT ))
define_vms $compute_machine_name $COMP_COUNT "profile:$compute_flavor_name,boot_option:local" $vbmc_port
(( vbmc_port+=COMP_COUNT ))
define_vms 'ctrlcont' $CONTRAIL_CONTROLLER_COUNT 'profile:contrail-controller,boot_option:local' $vbmc_port
(( vbmc_port+=CONTRAIL_CONTROLLER_COUNT ))
define_vms 'ctrlanalytics' $ANALYTICS_COUNT 'profile:contrail-analytics,boot_option:local' $vbmc_port
(( vbmc_port+=ANALYTICS_COUNT ))
define_vms 'ctrlanalyticsdb' $ANALYTICSDB_COUNT 'profile:contrail-analyticsdb,boot_option:local' $vbmc_port
(( vbmc_port+=ANALYTICSDB_COUNT ))
define_vms 'issu' $CONTRAIL_ISSU_COUNT 'profile:contrail-controller-issu,boot_option:local' $vbmc_port
(( vbmc_port+=CONTRAIL_ISSU_COUNT ))

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
#create_flavor 'baremetal' 1
create_flavor 'control' $CONT_COUNT 'controller'
create_flavor $compute_flavor_name $COMP_COUNT $compute_flavor_name
create_flavor 'contrail-controller' $CONTRAIL_CONTROLLER_COUNT 'contrail-controller'
create_flavor 'contrail-analytics' $ANALYTICS_COUNT 'contrail-analytics'
create_flavor 'contrail-analytics-database' $ANALYTICSDB_COUNT 'contrail-analyticsdb'
create_flavor 'contrail-controller-issu' $CONTRAIL_ISSU_COUNT 'contrail-controller-issu'

openstack flavor list --long

# cleanup old nodes
for i in $(openstack baremetal node list -f value -c UUID) ; do
  openstack baremetal node delete $i || true
done
# import overcloud configuration
openstack overcloud node import ~/instackenv.json
openstack baremetal node list
for i in {1..3} ; do
  openstack overcloud node introspect --all-manageable --provide
  if ! openstack baremetal node list 2>&1 | grep -q 'manageable' ; then
    break
  fi
  sleep 5
done
openstack baremetal node list

# this is a recommended command to check and wait end of introspection. but previous command can wait itself.
#sudo journalctl -l -u openstack-ironic-discoverd -u openstack-ironic-discoverd-dnsmasq -u openstack-ironic-conductor -f

git config --global user.name jenkins.progmaticlab
git config --global user.email jenkins@progmaticlab.com

# For queens there is no needs to use puppets
artifact_opts=""
git_branch_ctp="stable/${OPENSTACK_VERSION}"
if [[ "$CONTRAIL_VERSION" =~ 4.1 ]] ; then
  git_branch_pc="R4.1"
else
  git_branch_pc="R4.0"
fi
if [[ "$CONTRAIL_VERSION" =~ 5.0 ]] ; then
  git_branch_ccb='R5.0'
else
  git_branch_ccb='master'
fi
if [[ "$USE_DEVELOPMENT_PUPPETS" == 'true' ]] ; then
  git_repo_ctp="progmaticlab"
  git_repo_pc="progmaticlab"
  git_repo_ccb='progmaticlab'
else
  git_repo_ctp="Juniper"
  git_repo_pc="Juniper"
  git_repo_ccb='Juniper'
fi
if [[ 'newton|ocata|pike' =~ $OPENSTACK_VERSION ]] ; then
  # prepare Contrail puppet modules via uploading artifacts to swift
  rm -rf usr/share/openstack-puppet/modules
  mkdir -p usr/share/openstack-puppet/modules
  git clone https://github.com/${git_repo_ctp}/contrail-tripleo-puppet -b $git_branch_ctp usr/share/openstack-puppet/modules/tripleo
  if [[ -n "$TPP_PATCHSET" ]] ; then
    pushd usr/share/openstack-puppet/modules/tripleo
    bash -c "$TPP_PATCHSET"
    popd
  fi
  git clone https://github.com/${git_repo_pc}/puppet-contrail -b $git_branch_pc usr/share/openstack-puppet/modules/contrail
  if [[ -n "$PP_PATCHSET" ]] ; then
    pushd usr/share/openstack-puppet/modules/contrail
    bash -c "$PP_PATCHSET"
    popd
  fi
  tar czvf puppet-modules.tgz usr/
  upload-swift-artifacts -c contrail-artifacts -f puppet-modules.tgz
  artifact_opts="-e .tripleo/environments/deployment-artifacts.yaml"
else
  if [[ ! -d contrail-container-builder ]] ; then
    git clone -b $git_branch_ccb https://github.com/${git_repo_ccb}/contrail-container-builder
  else
    pushd contrail-container-builder
    git fetch --all
    git reset --hard origin/$git_branch_ccb
    popd
  fi
  if [[ -n "$CCB_PATCHSET" ]] ; then
    pushd contrail-container-builder
    bash -c "$CCB_PATCHSET"
    popd
  fi
  _old_cv=$CONTRAIL_VERSION
  export CONTRAIL_VERSION=$(ls -1 /var/www/html | grep -o '\([0-9]\+\.\{0,1\}\)\{1,5\}-[0-9]\+' | sort -nr  | head -n 1)
  if [[ "$USE_DEVELOPMENT_PUPPETS" == 'true' || -n "$TPP_PATCHSET" ]] ; then
    [ ! -d contrail-packages ] && git clone https://github.com/Juniper/contrail-packages
    pushd contrail-packages
    rm -rf RPMS openstack
    # update contrail-tripleo-puppet RPM
    git clone https://github.com/${git_repo_ctp}/contrail-tripleo-puppet -b $git_branch_ctp openstack/contrail-tripleo-puppet
    if [[ -n "$TPP_PATCHSET" ]] ; then
      pushd openstack/contrail-tripleo-puppet
      bash -c "$TPP_PATCHSET"
      popd
    fi
    make rpm-contrail-tripleo-puppet
    repo_dir="/var/www/html/${CONTRAIL_VERSION}"
    sudo rm -f $repo_dir/contrail-tripleo-puppet*.rpm
    sudo cp -f RPMS/noarch/*.rpm $repo_dir
    pushd $repo_dir
    sudo createrepo --update -v $repo_dir
    popd
    popd
  fi
  export _CONTRAIL_REGISTRY_IP=$prov_ip
  export CONTRAIL_REGISTRY="${prov_ip}:8787"
  export CONTRAIL_TAG="${OPENSTACK_VERSION}-${CONTRAIL_VERSION}"
  if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
    export LINUX_DISTR=${LINUX_DISTR:-'rhel7'}
    export LINUX_DISTR_VER=${LINUX_DISTR_VER:-'latest'}
    export GENERAL_EXTRA_RPMS=""
    export BASE_EXTRA_RPMS=""
  else
    export LINUX_DISTR=${LINUX_DISTR:-'centos'}
    export LINUX_DISTR_VER=${LINUX_DISTR_VER:-'7.4.1708'}
  fi
  # save for easier debug
  cat <<EOF > ~/build_env
export CONTRAIL_VERSION=$CONTRAIL_VERSION
export _CONTRAIL_REGISTRY_IP=$_CONTRAIL_REGISTRY_IP
export CONTRAIL_REGISTRY=$CONTRAIL_REGISTRY
export CONTRAIL_TAG=$CONTRAIL_TAG
export LINUX_DISTR=$LINUX_DISTR
export LINUX_DISTR_VER=$LINUX_DISTR_VER
[ -n "${GENERAL_EXTRA_RPMS+x}" ] && export GENERAL_EXTRA_RPMS="$GENERAL_EXTRA_RPMS"
[ -n "${BASE_EXTRA_RPMS+x}" ] && export BASE_EXTRA_RPMS="$BASE_EXTRA_RPMS"
EOF
  # add TPC repo
  cat <<EOF > contrail-container-builder/tpc.repo.template 
[tpc]
name = tpc
baseurl = http://148.251.5.90/tpc
enabled = 1
gpgcheck = 0
EOF
  pushd contrail-container-builder/containers
  # TODO: dont fail build because some containers like vcenter fails in our env
  ./build.sh || { echo "WARNING: some containers are failed." ; cat ./*.log || true ; }
  popd
  CONTRAIL_VERSION=$_old_cv
fi

# prepare tripleo heat templates
git_branch_tht="stable/${OPENSTACK_VERSION}"
git_repo_ctht="juniper"
if [[ "$USE_DEVELOPMENT_PUPPETS" == 'true' ]] ; then
  git_repo_ctht="progmaticlab"
fi
rm -rf ~/tripleo-heat-templates
cp -r /usr/share/openstack-tripleo-heat-templates/ ~/tripleo-heat-templates
# apply patch: https://review.openstack.org/#/c/625877/
#   for https://bugs.launchpad.net/tripleo/+bug/1808965
sed -i 's/\/usr\/share\/openstack-tripleo-heat-templates\/extraconfig\/pre_deploy\/rhel-registration\/scripts/scripts/g' tripleo-heat-templates/extraconfig/pre_deploy/rhel-registration/rhel-registration.yaml
#

rm -rf ~/contrail-tripleo-heat-templates
git clone https://github.com/${git_repo_ctht}/contrail-tripleo-heat-templates -b $git_branch_tht
if [[ -n "$THT_PATCHSET" ]] ; then
  pushd contrail-tripleo-heat-templates
  bash -c "$THT_PATCHSET"
  popd
fi
cp -r ~/contrail-tripleo-heat-templates/* ~/tripleo-heat-templates

if [[ ! 'newton|ocata|pike' =~ $OPENSTACK_VERSION && -f ~/tht_ipa.diff ]] ; then
  # apply https://review.openstack.org/#/c/625693/
  if patch --dry-run -p 1 -i ~/tht_ipa.diff -d ~/tripleo-heat-templates/ ; then
    patch -p 1 -i ~/tht_ipa.diff -d ~/tripleo-heat-templates/
  fi
fi

case "$OPENSTACK_VERSION" in
  newton)
    role_file='tripleo-heat-templates/environments/contrail/roles_data.yaml'
    ;;
  ocata|pike)
    role_file='tripleo-heat-templates/environments/contrail/roles_data_contrail.yaml'
    ;;
  *)    
    role_file='tripleo-heat-templates/roles_data_contrail_aio.yaml'
    if (( ANALYTICSDB_COUNT > 0 && ANALYTICS_COUNT > 0 )) ; then
      role_file='tripleo-heat-templates/roles_data_contrail_ffu.yaml'
    fi
    ;;
esac

# disable ceilometer
# there is the bug with 'ceilometer-upgrade --skipt-metering-database'
# https://bugs.launchpad.net/tripleo/+bug/1693339
# wich cause the deployement fails
sed -i  's/\(.*Ceilometer.*\)/#\1/g' $role_file

# set common deploy parameters for services
contrail_services_file='tripleo-heat-templates/environments/contrail/contrail-services.yaml'
sed -i "s/ContrailRepo:.*/ContrailRepo:  http:\/\/${prov_ip}\/contrail/g" $contrail_services_file
sed -i "s/ControllerCount:.*/ControllerCount: $CONT_COUNT/g" $contrail_services_file
sed -i "s/ContrailControllerCount:.*/ContrailControllerCount: $CONTRAIL_CONTROLLER_COUNT/g" $contrail_services_file
sed -i "s/ContrailAnalyticsCount:.*/ContrailAnalyticsCount: $ANALYTICS_COUNT/g" $contrail_services_file
sed -i "s/ContrailAnalyticsDatabaseCount:.*/ContrailAnalyticsDatabaseCount: $ANALYTICSDB_COUNT/g" $contrail_services_file
sed -i "s/ComputeCount:.*/ComputeCount: $comp_scale_count/g" $contrail_services_file
sed -i "s/ContrailDpdkCount:.*/ContrailDpdkCount: $dpdk_scale_count/g" $contrail_services_file
sed -i "s/ContrailTsnCount:.*/ContrailTsnCount: $tsn_scale_count/g" $contrail_services_file
sed -i 's/NtpServer:.*/NtpServer: 3.europe.pool.ntp.org/g' $contrail_services_file
if [[ "$DPDK" != 'off' ]] ; then
  dpdk_nic_file='tripleo-heat-templates/network/config/contrail/examples/dpdk/contrail-dpdk-nic-config-single.yaml'
  if [[ "$DPDK" == 'default' ]] ; then
    [[ ! 'newton|ocata|pike' =~ $OPENSTACK_VERSION ]] && {
      sed -i "/driver:.*/d" $dpdk_nic_file
      sed -i "s/cpu_list:.*/cpu_list: '$dpdk_core_mask'/g" $dpdk_nic_file
    }
  else
    sed -i "s/.*ContrailDpdkDriver:.*/  ContrailDpdkDriver: $DPDK/g" $contrail_services_file
    [[ ! 'newton|ocata|pike' =~ $OPENSTACK_VERSION ]] && {
      sed -i "s/driver:.*/driver: $DPDK/g" $dpdk_nic_file
      sed -i "s/cpu_list:.*/cpu_list: '$dpdk_core_mask'/g" $dpdk_nic_file
    }
  fi
fi
# set network parameters
# TODO: temporary use always single nic
# if [[ "$NETWORK_ISOLATION" != 'single' || "$DPDK" == 'true' ]] ; then
#   use_multi_nic='yes'
#   contrail_net_file='tripleo-heat-templates/environments/contrail/contrail-net.yaml'
#   vrouter_iface='ens4'
# else
#   use_multi_nic='no'
#   vrouter_iface='ens3'
#   contrail_net_file='tripleo-heat-templates/environments/contrail/contrail-net-single.yaml'
# fi
use_multi_nic='no'
vrouter_iface='ens3'
contrail_net_file='tripleo-heat-templates/environments/contrail/contrail-net-single.yaml'

sed -i "s/ControlPlaneDefaultRoute:.*/ControlPlaneDefaultRoute: ${prov_ip}/g" $contrail_net_file
sed -i "s/EC2MetadataIp:.*/EC2MetadataIp: ${prov_ip}/g" $contrail_net_file
if [[ 'newton|ocata|pike' =~ $OPENSTACK_VERSION ]] ; then
  if [[ "$OPENSTACK_VERSION" == 'newton' ]] ; then
    sed -i "s/VrouterPhysicalInterface:.*/VrouterPhysicalInterface: ${vrouter_iface}/g" $contrail_net_file
    sed -i "s/VrouterDpdkPhysicalInterface:.*/VrouterDpdkPhysicalInterface: ${vrouter_iface}/g" $contrail_net_file
    sed -i "s/VrouterGateway:.*/VrouterGateway: ${prov_ip}/g" $contrail_net_file
  else
    sed -i "s/ContrailVrouterPhysicalInterface:.*/ContrailVrouterPhysicalInterface: ${vrouter_iface}/g" $contrail_net_file
    sed -i "s/ContrailVrouterDpdkPhysicalInterface:.*/ContrailVrouterDpdkPhysicalInterface: ${vrouter_iface}/g" $contrail_net_file
    sed -i "s/ContrailVrouterGateway:.*/ContrailVrouterGateway: ${prov_ip}/g" $contrail_net_file
  fi
else
  #OSP13
  # TODO: disable VROUTER_GATEWAY for testing 
  sed -i "s/VROUTER_GATEWAY:.*/#VROUTER_GATEWAY: ${prov_ip}/g" $contrail_services_file
fi
sed -i "s/ControlVirtualInterface:.*/ControlVirtualInterface: ens3/g" $contrail_net_file
sed -i "s/PublicVirtualInterface:.*/PublicVirtualInterface: ens3/g" $contrail_net_file
sed -i 's/NtpServer:.*/NtpServer: 3.europe.pool.ntp.org/g' $contrail_net_file

if [[ "$FREE_IPA" == 'true' ]] ; then
  sed -i "s/DnsServers:.*/DnsServers: [\"$ipa_ip\",\"8.8.8.8\",\"8.8.4.4\"]/g" $contrail_net_file
else
  sed -i 's/DnsServers:.*/DnsServers: ["8.8.8.8","8.8.4.4"]/g' $contrail_net_file
fi

# file for other options
misc_opts='misc_opts.yaml'
rm -f $misc_opts
touch $misc_opts


# TODO: OSP13: for queens only 3 contrail controller nodes are for now
# (no separate analytics and analytics db nodes)
if [[ 'newton|ocata|pike' =~ $OPENSTACK_VERSION ]] ; then

  # add sshd service for computes
  pos_to_insert=`sed "=" $role_file | sed -n '/^- name: Compute/,/^  ServicesDefault:/p' | grep -o '^[0-9]\+' | tail -n 1`
  sed -i "${pos_to_insert} a\\    - OS::TripleO::Services::Sshd" $role_file
  pos_to_insert=`sed "=" $role_file | sed -n '/^- name: ContrailDpdk/,/^  ServicesDefault:/p' | grep -o '^[0-9]\+' | tail -n 1`
  sed -i "${pos_to_insert} a\\    - OS::TripleO::Services::Sshd" $role_file

  # Create ports for Contrail Controller and/or Analytis if any is installed on own node.
  # In that case OS controller will host VIP and haproxy will forward requests.
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
  OS::TripleO::ContrailControllerVirtualIPs: OS::Heat::None
EOF
    echo INFO: add contrail controller services to OS Controller role
    pos_to_insert=`sed "=" $role_file | sed -n '/^- name: Controller/,/^  ServicesDefault:/p' | grep -o '^[0-9]\+' | tail -n 1`
    to_add='    - OS::TripleO::Services::ContrailConfig\n    - OS::TripleO::Services::ContrailControl\n'
    to_add+='    - OS::TripleO::Services::ContrailDatabase\n    - OS::TripleO::Services::ContrailWebUI'
    sed -i "${pos_to_insert} a\\$to_add" $role_file
  fi

  if (( ANALYTICS_COUNT > 0 || CONTRAIL_CONTROLLER_COUNT > 0 )) ; then
    if (( ANALYTICS_COUNT > 0 )) ; then
      echo INFO: contrail analytics is installed on own nodes, prepare VIPs env file
    else
      echo INFO: contrail analytics is installed on contrail controller nodes, prepare VIPs env file and put analytics service into ContralController role
      pos_to_insert=`sed "=" $role_file | sed -n '/^- name: ContrailController/,/^  ServicesDefault:/p' | grep -o '^[0-9]\+' | tail -n 1`
      sed -i "${pos_to_insert} a\\    - OS::TripleO::Services::ContrailAnalytics" $role_file
    fi
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
    cat <<EOF >> $contrail_vip_env
  OS::TripleO::ContrailAnalyticsVirtualIPs: OS::Heat::None
EOF
    echo INFO: add contrail analytics services to OS Controller role
    pos_to_insert=`sed "=" $role_file | sed -n '/^- name: Controller/,/^  ServicesDefault:/p' | grep -o '^[0-9]\+' | tail -n 1`
    sed -i "${pos_to_insert} a\\    - OS::TripleO::Services::ContrailAnalytics" $role_file
  fi
  if (( ANALYTICSDB_COUNT > 0 )) ; then
    echo INFO: contrail analyticsdb is installed on the own node
  else
    # disable services that are not-exists in R4.0
    # they prevent to install containers on one node because
    # of puppet resource declaraion duplication
    sed -i 's/OS::TripleO::Services::ContrailControl:.*/OS::TripleO::Services::ContrailControl: OS::Heat::None/g' $contrail_services_file
    sed -i 's/OS::TripleO::Services::ContrailDatabase:.*/OS::TripleO::Services::ContrailDatabase: OS::Heat::None/g' $contrail_services_file
    # sed -i 's/OS::TripleO::Services::ContrailWebUI:.*/OS::TripleO::Services::ContrailWebUI: OS::Heat::None/g' $contrail_services_file
    if (( CONTRAIL_CONTROLLER_COUNT > 0 )) ; then
      echo INFO: contrail analyticsdb is installed on contrail controller nodes, put analyticsdb service into ContralController role
      pos_to_insert=`sed "=" $role_file | sed -n '/^- name: ContrailController/,/^  ServicesDefault:/p' | grep -o '^[0-9]\+' | tail -n 1`
    else
      echo INFO: add contrail analyticsdb services to OS Controller role
      pos_to_insert=`sed "=" $role_file | sed -n '/^- name: Controller/,/^  ServicesDefault:/p' | grep -o '^[0-9]\+' | tail -n 1`
    fi
    sed -i "${pos_to_insert} a\\    - OS::TripleO::Services::ContrailAnalyticsDatabase" $role_file
    # add simulation contrail_database_node_ips
    if ! grep -q 'resource_registry:' $misc_opts ;  then
      cat <<EOF >> $misc_opts
resource_registry:
EOF
    fi
    cat <<EOF >> $misc_opts
    OS::TripleO::Services::ContrailControl: simulate_contrail_control.yaml
    OS::TripleO::Services::ContrailDatabase: simulate_contrail_database.yaml
EOF
    cat <<EOF > simulate_contrail_database.yaml
heat_template_version: 2016-10-14
parameters:
  ServiceNetMap:
    default: {}
    type: json
  DefaultPasswords:
    default: {}
    type: json
  EndpointMap:
    default: {}
    type: json
outputs:
  role_data:
    value:
      service_name: contrail_database
      config_settings:
        contrail_database_sim: 'contrail_database_sim'
EOF
    cat <<EOF > simulate_contrail_control.yaml
heat_template_version: 2016-10-14
parameters:
  ServiceNetMap:
    default: {}
    type: json
  DefaultPasswords:
    default: {}
    type: json
  EndpointMap:
    default: {}
    type: json
outputs:
  role_data:
    value:
      service_name: contrail_control
      config_settings:
        contrail_control_sim: 'contrail_control_sim'
EOF
  fi
fi # if [[ 'newton|ocata|pike' =~ $OPENSTACK_VERSION ]]

# other options
if [[ "$DPDK" != 'off' && "$OPENSTACK_VERSION" == 'newton' ]] ; then
  if ! grep -q 'resource_registry:' $misc_opts ;  then
  cat <<EOF >> $misc_opts
resource_registry:
EOF
  fi
  if [[ "$NETWORK_ISOLATION" == 'single' ]] ; then
    cat <<EOF >> $misc_opts
  OS::TripleO::ContrailDpdk::Net::SoftwareConfig: tripleo-heat-templates/environments/contrail/contrail-nic-config-compute-single.yaml
EOF
  else
    echo "Error: DPDK is not supported for $NETWORK_ISOLATION"
    exit -1
  fi
fi

cat <<EOF >> $misc_opts
parameter_defaults:
  ControlFixedIPs: [{'ip_address':'$fixed_vip'}]
  CloudDomain: $CLOUD_DOMAIN_NAME
  GlanceBackend: file
  RabbitUserName: contrail
  RabbitPassword: contrail
  ContrailInsecure: true
  AdminPassword: qwe123QWE
  ContrailWebuiHttp: 8180
  ContrailConfigDBMinDiskGB: 4
  ContrailAnalyticsDBMinDiskGB: 4
  ContrailAuthVersion: $KEYSTONE_API_VERSION
EOF


if [[ 'newton|ocata|pike' =~ $OPENSTACK_VERSION  ]] ; then
  cat <<EOF >> $misc_opts
  AAAMode: $AAA_MODE
  AAAModeAnalytics: $AAA_MODE_ANALYTICS
EOF
else
  if [[ "$AAA_MODE" != "$AAA_MODE_ANALYTICS" ]] ; then
    cat <<EOF >> $misc_opts
  ContrailControllerParameters:
    AAAMode: $AAA_MODE
  ContrailAnalyticsParameters:
    AAAMode: $AAA_MODE_ANALYTICS
EOF
  else
  cat <<EOF >> $misc_opts
  AAAMode: $AAA_MODE
EOF
  fi
fi


if [[ "$CONTRAIL_VERSION" =~ '3.2' ]] ; then
cat <<EOF >> $misc_opts
  ContrailVersion: 3
EOF
fi
if [[ -n "$BUILD_TAG" ]] ; then
cat <<EOF >> $misc_opts
  ContrailContainerTag: $BUILD_TAG
EOF
fi
if [[ "$FREE_IPA" == 'true' ]] ; then
cat <<EOF >> $misc_opts
  CloudName: overcloud.$CLOUD_DOMAIN_NAME
  CloudNameInternal: overcloud.internalapi.$CLOUD_DOMAIN_NAME
  CloudNameCtlplane: overcloud.ctlplane.$CLOUD_DOMAIN_NAME
EOF
fi

  # Add ssh keys for enabling nova migration over ssh
  cat <<EOF >> $misc_opts
  MigrationSshKey:
    private_key: |
EOF
  while read l ; do echo "      $l" ; done < ~/.ssh/id_rsa >> $misc_opts
  cat <<EOF >> $misc_opts
    public_key: |
EOF
  while read l ; do echo "      $l" ; done < ~/.ssh/id_rsa.pub >> $misc_opts

# IMPORTANT: The DNS domain used for the hosts should match the dhcp_domain configured in the Undercloud neutron.
if (( CONT_COUNT < 2 )) ; then
  echo "  EnableGalera: false" >> $misc_opts
fi

cat <<EOF >> $misc_opts
  ContrailControlRNDCSecret: sHE1SM8nsySdgsoRxwARtA==
EOF

dpdk_core_mask="0x07"
if [[ "$DPDK" != 'off' ]] ; then
  cat <<EOF >> $misc_opts
  ContrailDpdkCoremask: "$dpdk_core_mask"
  # 3.x/4.x
  ContrailDpdkHugePages: '1000'
  # 5.x
  ContrailDpdkHugepages1GB: 2
  ContrailDpdkHugepages2MB: 1000
EOF
fi

if [[ "$TSN" == 'true' ]] ; then
  cat <<EOF >> $misc_opts
  ContrailVrouterTSNEVPNMode: true
EOF
fi

if [[ "$CONTRAIL_VERSION" =~ 5.0 ]] ; then
  cat << EOF >>  $misc_opts
  DockerContrailAnalyticsTopologyImageName: 'contrail-analytics-topology'
EOF
fi

multi_nic_opts=''
if [[ "$use_multi_nic" == 'yes' ]] ; then
  multi_nic_opts+=' -e tripleo-heat-templates/environments/network-management.yaml'
  multi_nic_opts+=' -e tripleo-heat-templates/environments/contrail/network-isolation.yaml'
fi

use_pacemaker='false'
if [[ ! 'newton|ocata|pike' =~ $OPENSTACK_VERSION ]] ; then
  # osp13 doesnt work with VIPs w/o it,
  # keepalived service is not deployed with haproxy,
  # is it a bug?
  use_pacemaker='true'
fi
if (( CONT_COUNT > 1 )) ; then
  use_pacemaker='true'
fi

ha_opts=''
if [[ "$use_pacemaker" != 'false' ]] ; then
  ha_opts="-e tripleo-heat-templates/environments/puppet-pacemaker.yaml"
fi

sriov_opts=''
if [[ "$SRIOV" == 'true' ]] ; then
  sriov_file='tripleo-heat-templates/environments/contrail/contrail-sriov.yaml'
  cat <<EOF >> $sriov_file
  NeutronSriovNumVFs: "ens3:1"
  NovaPCIPassthrough:
    - devname: "ens3"
      physical_network: "datacentre"
EOF
  sriov_opts+=" -e $sriov_file"
fi

ssl_opts=''
if [[ "$TLS" != 'off' && "$FREE_IPA" == 'true' ]] ; then
  ssl_opts+=' -e tripleo-heat-templates/environments/contrail/contrail-tls.yaml'

  if [[  "$TLS" == 'all' ]] ; then
    ssl_opts+=' -e tripleo-heat-templates/environments/ssl/tls-everywhere-endpoints-dns.yaml'
    ssl_opts+=' -e tripleo-heat-templates/environments/services/haproxy-public-tls-certmonger.yaml'
    ssl_opts+=' -e tripleo-heat-templates/environments/ssl/enable-internal-tls.yaml'
  fi
fi

if [[ "$TLS" != 'off' && "$FREE_IPA" != 'true' ]] ; then
  # prepare for certificates creation
  ssl_working_dir="$(pwd)/contrail_ssl_gen"
  csr_file="${ssl_working_dir}/server.pem.csr"
  openssl_config_file="${ssl_working_dir}/contrail_openssl.cfg"
  rm -rf $ssl_working_dir
  mkdir -p $ssl_working_dir/certs
  touch ${ssl_working_dir}/index.txt ${ssl_working_dir}/index.txt.attr
  echo 1000 >${ssl_working_dir}/serial.txt
  cat <<EOF > $openssl_config_file
[req]
default_bits = 2048
prompt = no
default_md = sha256
default_days = 375
req_extensions = v3_req
distinguished_name = req_distinguished_name
x509_extensions = v3_ca

[ req_distinguished_name ]
countryName = US
stateOrProvinceName = California
localityName = Sannyvale
0.organizationName = OpenContrail
commonName = `hostname`

[ v3_req ]
basicConstraints = CA:false
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = `hostname`
DNS.2 = `hostname -f`
IP.1 = ${prov_ip}
IP.2 = ${mgmt_ip}

[ ca ]
default_ca = CA_default

[ CA_default ]
# Directory and file locations.
dir               = $ssl_working_dir
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/certs
database          = \$dir/index.txt
serial            = \$dir/serial.txt
RANDFILE          = \$dir/.rand
# For certificate revocation lists.
crlnumber         = \$dir/crlnumber
crl               = \$dir/crl/crl.pem
crl_extensions    = crl_ext
default_crl_days  = 30
# The root key and root certificate.
private_key       = ca.key.pem
certificate       = ca.crt.pem
# SHA-1 is deprecated, so use SHA-2 instead.
default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = 375
preserve          = no
policy            = policy_optional

[ policy_optional ]
countryName            = optional
stateOrProvinceName    = optional
organizationName       = optional
organizationalUnitName = optional
commonName             = supplied
emailAddress           = optional

[ v3_ca]
# Extensions for a typical CA
# PKIX recommendation.
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer:always
basicConstraints = CA:true

[ crl_ext ]
authorityKeyIdentifier=keyid:always,issuer:always
EOF

  # create root CA
  openssl genrsa -out ca.key.pem 4096
  openssl req -config $openssl_config_file -new -x509 -days 365 -extensions v3_ca -key ca.key.pem -out ca.crt.pem

  # create contrail root CA
  openssl genrsa -out contrail.ca.key.pem 4096
  openssl req -config $openssl_config_file -new -x509 -days 365 -extensions v3_ca -key contrail.ca.key.pem -out contrail.ca.crt.pem

  # create haproxy server certificate (VIPs)
  sed -i "s/commonName = .*/commonName = overcloud-controller-0/g" $openssl_config_file
  sed -i "s/DNS.1 = .*/DNS.1 = overcloud-controller-0/g" $openssl_config_file
  sed -i "s/DNS.2 = .*/DNS.2 = overcloud-controller-0.${CLOUD_DOMAIN_NAME}/g" $openssl_config_file
  sed -i "s/IP.1 = .*/IP.1 = ${fixed_vip}/g" $openssl_config_file
  sed -i "s/IP.2 = .*/IP.2 = ${fixed_controller_ip}/g" $openssl_config_file

  openssl genrsa -out server.key.pem 2048
  openssl req -config $openssl_config_file -new -key server.key.pem -new -out server.csr.pem
  yes | openssl ca -config $openssl_config_file -extensions v3_req -days 365 -in server.csr.pem -out server.crt.pem


  # create keystone certificate
  # TODO: is not used in newton
#  openssl genrsa -out keystone.key.pem 2048
#  openssl req -key keystone.key.pem -new -out keystone.csr.pem \
#    -subj "/C=RU/ST=Moscow/L=Moscow/O=ProgmaticLab/OU=TestKeystone/CN=${fixed_vip}"
#  yes | sudo openssl ca -extensions v3_req -days 365 -in keystone.csr.pem \
#    -out keystone.crt.pem -cert ca.crt.pem -keyfile ca.key.pem
#  sudo chown stack:stack keystone.crt.pem

  ssl_opts+=' -e enable-tls.yaml'
  if [[ ! 'newton|ocata|pike' =~ $OPENSTACK_VERSION  ]] ; then
    ssl_opts+=" -e tripleo-heat-templates/environments/contrail/contrail-tls.yaml"
  fi
  if [[ "$OPENSTACK_VERSION" == 'newton' ]] ; then
    endpoints_file='tripleo-heat-templates/environments/tls-endpoints-public-ip.yaml'
  else
    endpoints_file='tripleo-heat-templates/environments/ssl/tls-endpoints-public-ip.yaml'
  fi
  
  ssl_opts+=" -e $endpoints_file"
  cat <<EOF > ctlplane-port.yaml
parameters:
  Hostname:
    type: string
  DeployedServerPortMap:
    default: {}
    type: json
outputs:
  ip_address:
    value: {get_param: [DeployedServerPortMap, {get_param: Hostname}, ip_address]}
EOF

  cat <<EOF > enable-tls.yaml
resource_registry:
  # OS::TripleO::Controller::Ports::InternalApiPort: tripleo-heat-templates/network/ports/internal_api_from_pool.yaml
  OS::TripleO::Controller::ControlPlanePort: ctlplane-port.yaml
EOF

  cat <<EOF >> enable-tls.yaml
  OS::TripleO::NodeTLSData: tripleo-heat-templates/puppet/extraconfig/tls/tls-cert-inject.yaml
  OS::TripleO::NodeTLSCAData: tripleo-heat-templates/puppet/extraconfig/tls/ca-inject.yaml
EOF

  cat <<EOF >> enable-tls.yaml
parameter_defaults:
  # ControllerIPs:
  #   ctlplane:
  #     - $fixed_controller_ip
  DeployedServerPortMap:
    controller-ctlplane:
      - ip_address: $fixed_controller_ip
EOF
  if [[ "$TLS" == 'all' || "$TLS" == 'all_except_rabbit' ]] ; then
    sed -i 's/\(Admin\)\(.*\)http/\1\2https/g' $endpoints_file
    sed -i 's/\(Internal\)\(.*\)http/\1\2https/g' $endpoints_file
    cat <<EOF >> enable-tls.yaml
  # enable internal TLS
  ContrailInternalApiSsl: true
EOF
    if [[ "$OPENSTACK_VERSION" == "newton" ]] ; then
      cat <<EOF >> enable-tls.yaml
  # enable internal TLS
  controllerExtraConfig:
    tripleo::haproxy::internal_certificate: /etc/pki/tls/private/overcloud_endpoint.pem
EOF
    elif [[ 'ocata|pike' =~ $OPENSTACK_VERSION  ]] ; then
      cat <<EOF >> enable-tls.yaml
  # enable internal TLS
  controllerExtraConfig:
    tripleo::haproxy::use_internal_certificates: true
    tripleo::profile::base::haproxy::certificates_specs:
      haproxy-internal_api:
        service_pem: /etc/pki/tls/private/overcloud_endpoint.pem
      haproxy-ctlplane:
        service_pem: /etc/pki/tls/private/overcloud_endpoint.pem
      haproxy-storage:
        service_pem: /etc/pki/tls/private/overcloud_endpoint.pem
      haproxy-storage_mgmt:
        service_pem: /etc/pki/tls/private/overcloud_endpoint.pem
EOF
    else
      # queens
      ssl_opts+=" -e tripleo-heat-templates/environments/ssl/enable-internal-tls.yaml"
      cat <<EOF >> enable-tls.yaml
  CertmongerCA: 'local'
  CertmongerVncCA: 'local'
EOF
    fi
  fi

  if [[ "$TLS" == 'all' ]] ; then
    cat <<EOF >> enable-tls.yaml
  RabbitClientUseSSL: true
EOF
  fi
  
  cat <<EOF >> enable-tls.yaml
  ContrailSslEnabled: true
  ContrailInsecure: false
  SSLIntermediateCertificate: ''
  SSLCertificate: |
EOF
  sed '/BEGIN CERTIFICATE/,/END CERTIFICATE/!d' server.crt.pem > clean.server.crt.pem
  while read l ; do echo "    $l" ; done < clean.server.crt.pem >> enable-tls.yaml
  echo "  SSLKey: |" >> enable-tls.yaml
  while read l ; do echo "    $l" ; done < server.key.pem >> enable-tls.yaml

  echo "  SSLRootCertificate: |" >> enable-tls.yaml
  while read l ; do echo "    $l" ; done < ca.crt.pem >> enable-tls.yaml

  echo "  ContrailCaCert: |" >> enable-tls.yaml
  while read l ; do echo "    $l" ; done < contrail.ca.crt.pem >> enable-tls.yaml
  echo "  ContrailCaKey: |" >> enable-tls.yaml
  while read l ; do echo "    $l" ; done < contrail.ca.key.pem >> enable-tls.yaml

  echo "  ContrailAuthCaCert: |" >> enable-tls.yaml
  while read l ; do echo "    $l" ; done < ca.crt.pem >> enable-tls.yaml

# TODO: not used in newton
#  echo "  KeystoneSSLCertificate: |" >> enable-tls.yaml
#  sed '/BEGIN CERTIFICATE/,/END CERTIFICATE/!d' keystone.crt.pem > clean.keystone.crt.pem
#  while read l ; do echo "    $l" ; done < clean.keystone.crt.pem >> enable-tls.yaml
#  echo "  KeystoneSSLCertificateKey: |" >> enable-tls.yaml
#  while read l ; do echo "    $l" ; done < keystone.key.pem >> enable-tls.yaml

fi

contrail_vip_env_opts="-e $contrail_vip_env"
docker_opts=''
openstack_ver_specific=''
if [[ ! 'newton|ocata|pike' =~ $OPENSTACK_VERSION ]] ; then
  contrail_vip_env_opts=''
  openstack_ver_specific=' -e tripleo-heat-templates/environments/contrail/contrail-plugins.yaml'

  sed -i "s/.*ContrailRegistry:.*/  ContrailRegistry: $CONTRAIL_REGISTRY/g" $contrail_services_file
  sed -i "s/.*ContrailImageTag:.*/  ContrailImageTag: $CONTRAIL_TAG/g" $contrail_services_file
  sed -i "s/.*ContrailRegistryInsecure:.*/  ContrailRegistryInsecure: True/g" $contrail_services_file
  sed -i "s/.*ContrailRegistryCertUrl:.*/  ContrailRegistryCertUrl: ''/g" $contrail_services_file

  image_namespace="docker.io/tripleo${OPENSTACK_VERSION}"
  tag_opts='--tag current-tripleo-rdo'
  tag_from_label_opts='--tag-from-label rdo_version'
  prefix_opts=''
  docker_opt=' -e docker_registry.yaml'
  if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
    # OSP13
    # image_namespace="registry.access.redhat.com/rhosp13-beta"
    image_namespace="registry.access.redhat.com/rhosp13"
    tag_opts=''
    tag_from_label_opts='--tag-from-label {version}-{release}'
    prefix_opts="--prefix=openstack-"
  else
    # OSP13 doesnt use it, but for opensorce tripleo it is needed...
    docker_opt+=' -e tripleo-heat-templates/environments/docker.yaml'
  fi

  openstack overcloud container image prepare \
    --namespace $image_namespace $tag_opts $prefix_opts $tag_from_label_opts \
    --push-destination ${prov_ip}:8787 \
    --output-env-file ~/docker_registry.yaml \
    --output-images-file ~/overcloud_containers.yaml

  openstack overcloud container image upload --config-file ~/overcloud_containers.yaml
fi

rhel_reg_opts=''
rhel_account_file_name=$(echo $RHEL_ACCOUNT_FILE | awk -F '/' '{print($NF)}')
if [ -f ~/$rhel_account_file_name ] ; then
  set +x
  source ~/$rhel_account_file_name
  cat <<EOF > environment-rhel-registration.yaml
parameter_defaults:
  rhel_reg_activation_key: "$RHEL_ACTIVATION_KEY"
  rhel_reg_auto_attach: ""
  rhel_reg_base_url: ""
  rhel_reg_environment: ""
  rhel_reg_force: ""
  rhel_reg_machine_name: ""
  rhel_reg_org: "$RHEL_ORG"
  rhel_reg_password: "$RHEL_PASSWORD"
  rhel_reg_pool_id: "$RHEL_POOL_ID"
  rhel_reg_release: ""
  rhel_reg_repos: "$RHEL_REPOS"
  rhel_reg_sat_url: ""
  rhel_reg_server_url: ""
  rhel_reg_service_level: ""
  rhel_reg_user: "$RHEL_USER"
  rhel_reg_type: ""
  rhel_reg_method: "portal"
  rhel_reg_sat_repo: ""
  rhel_reg_http_proxy_host: ""
  rhel_reg_http_proxy_port: ""
  rhel_reg_http_proxy_username: ""
  rhel_reg_http_proxy_password: ""
EOF
  set -x
  rhel_reg_opts+="-e environment-rhel-registration.yaml"
  rhel_reg_opts+=" -e tripleo-heat-templates/extraconfig/pre_deploy/rhel-registration/rhel-registration-resource-registry.yaml"
fi

if [[ "$DEPLOY" != '1' ]] ; then
  # deploy overcloud. if you do it manually then I recommend to do it in screen.
  echo "openstack overcloud deploy --templates tripleo-heat-templates/ \
      --roles-file $role_file \
      $rhel_reg_opts \
      $artifact_opts \
      -e $contrail_services_file \
      -e $contrail_net_file \
      -e $misc_opts \
      $contrail_vip_env_opts \
      $openstack_ver_specific \
      $ssl_opts \
      $multi_nic_opts \
      $ha_opts \
      $sriov_opts \
      $docker_opt"
  echo "Add '-e templates/firstboot/firstboot.yaml' if you use swap"
  exit
fi

# script will handle errors below
set +e

# for queens+ run process script that generates some yamls for TLS
if [[ ! 'newton|ocata|pike' =~ $OPENSTACK_VERSION ]] ; then
  python ~/tripleo-heat-templates/tools/process-templates.py  --safe \
    -r ~/tripleo-heat-templates/roles_data_contrail_aio.yaml \
    -p ~/tripleo-heat-templates/
fi

openstack overcloud deploy --templates tripleo-heat-templates/ \
  --roles-file $role_file \
  $rhel_reg_opts \
  $artifact_opts \
  -e $contrail_services_file \
  -e $contrail_net_file \
  -e $misc_opts \
  $contrail_vip_env_opts $openstack_ver_specific $ssl_opts $multi_nic_opts $ha_opts $sriov_opts $docker_opt

errors=$?

echo "Update /etc/hosts to resolve fqdn for overcloud VIP"

sudo sed -e "/overcloud.${CLOUD_DOMAIN_NAME}/d" /etc/hosts
sudo bash -c "echo \"${fixed_vip} overcloud.${CLOUD_DOMAIN_NAME}\" >> /etc/hosts"

echo "INFO: overcloud nodes"
overcloud_nodes=$(openstack server list)
echo "$overcloud_nodes"

retry=1
while (true) ; do
  sleep 30
  echo "INFO: collecting Contrail status, try $retry"
  status_chek_res=0
  for i in `echo "$overcloud_nodes" | awk '/contrail|compute|dpdk|tsn/ {print($8)}' | cut -d '=' -f 2` ; do
      contrail_status="$(ssh heat-admin@${i} sudo contrail-status)"
      hostname="$(ssh heat-admin@${i} hostname)"
      echo "==== $i ===="
      echo "$contrail_status"

      if [[ 'newton|ocata' =~ $OPENSTACK_VERSION ]] ; then
        if [[ ! $hostname =~ 'contrailcontroller' ]] ; then
          state=`echo "$contrail_status" | grep -v '==' |  awk '{print($2)}'`
        else
          state=`echo "$contrail_status" | grep -v '==' |  grep -v 'supervisor-database' | awk '{print($2)}'`
        fi
        for st in $state; do
          if  [[ ! "active timeout backup" =~ "$st" ]] ; then
            ((++status_chek_res))
          fi
        done
      else
        total_count=$(echo "$contrail_status" | awk '/^.*:/{print($2)}' | wc -l)
        active_count=$(echo "$contrail_status" | awk '/^.*:/{print($2)}' | grep 'active' | wc -l)
        if (( total_count != active_count )) ; then
            ((++status_chek_res))
        fi
      fi
  done
  if (( status_chek_res == 0 )) ; then
    break
  fi
  ((++retry))
  if (( retry > 10 )) ; then
    echo "ERROR: some of contrail services are not in active state:"
    ((++errors))
    break
  fi
done


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

if [[ "$RHEL_CERT_TEST" == 'true' ]] ; then
  if  ! openstack role list | grep -q Member ; then
    openstack role create Member
  fi
  for ip in `openstack server list  | awk '/overcloud/ {print($8)}' | cut -d '=' -f 2` ; do
    cat << EOF  | ssh -T heat-admin@${ip}
    sudo iptables -I INPUT 1 -p tcp -m multiport --dports 8009 -m comment --comment \"rhcertd\" -m state --state NEW -j ACCEPT
    sudo iptables -I INPUT 2 -p udp -m multiport --dports 8009 -m comment --comment \"rhcertd\" -m state --state NEW -j ACCEPT
    sudo yum install -y redhat-certification-openstack
    sudo rhcertd restart
EOF
  done
fi
