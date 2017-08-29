#!/bin/bash -e

set -x

if [[ "$HOME" == "" ]] ; then
  echo "ERROR: HOME variable must be set"
  exit 1
fi

# base constants for SandBox

export VERSION=${VERSION:-'49'}
export CHARMS_VERSION=${CHARMS_VERSION:-'b0a8b421b124564518ed8a95b223613fc0a883c3'}
# here must be trusty-mitaka or xenial-newton
export SERIES=${SERIES:-'trusty'}
export OPENSTACK_VERSION=${OPENSTACK_VERSION:-'mitaka'}
export PASSWORD=${PASSWORD:-'password'}
OPENSTACK_ORIGIN="cloud:${SERIES}-${OPENSTACK_VERSION}"
addresses_store_file="$HOME/.addresses"
base_url='https://s3-us-west-2.amazonaws.com/contrailpkgs'
suffix='ubuntu14.04-4.0.1.0'
export WORKSPACE="$HOME"
export SANDBOX_MODE='true'

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
my_pid=$$

function log_info() {
  echo "$(date) INFO: $@"
}

function set_status() {
  log_info "$@"
  cat >deploy_status.$my_pid <<EOF
$stage
$stages_count
$@
EOF
}

function reset_status() {
  log_info "Waiting for deployment..."
  rm -f deploy_status.$my_pid
}

cd "$HOME"

stage=0
# count stages in this file by yourself and place the count here for status
stages_count=12

set_status "start deploying..."

set_status "setting juju credentials"
$my_dir/_set-juju-creds.sh
if juju status ; then
  # deployment already exists
  rm -f deploy_status.$my_pid
  exit 5
fi

set_status "detecting instance details"
instance_id=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r ".instanceId"`
log_info "Instance ID is $instance_id"
mac_url='http://169.254.169.254/latest/meta-data/network/interfaces/macs/'
mac=`curl -s $mac_url`
log_info "MAC is $mac"
vpc_id=`curl -s ${mac_url}${mac}vpc-id`
log_info "VPC_ID is $vpc_id"
subnet_id=`curl -s ${mac_url}${mac}subnet-id`
log_info "SUBNET_ID is $subnet_id"
private_ip=`curl -s ${mac_url}${mac}local-ipv4s`
log_info "PRIVATE_IP is $private_ip"

# change directory to working directory
cdir="$(pwd)"
log_info "working in the HOME directory = $HOME"

set_status "bootstrapping juju"
juju --debug bootstrap --bootstrap-series=$SERIES aws amazon --config vpc-id=$vpc_id --config vpc-id-force=true

stage=1

set_status "cloning contrail-charms repository at point $CHARMS_VERSION"
rm -rf contrail-charms
git clone https://github.com/Juniper/contrail-charms.git
cd contrail-charms
git checkout $CHARMS_VERSION
cd ..

stage=2

# NOTE: next operations (downloading all archives) can take from 1 minute to 10 minutes or more.
# so now script doesn't delete/re-download archives if something with same file name is present.
mkdir -p docker

function get_file() {
  local f_name="$1"
  if [ ! -f "docker/$f_name" ] ; then
    set_status "downloading '$f_name'"
    wget -nv "${base_url}/$f_name" -O "docker/$f_name"
  else
    set_status "'$f_name' found. skipping downloading."
  fi
}

get_file "contrail-analytics-${suffix}-${VERSION}.tar.gz"
stage=3
get_file "contrail-analyticsdb-${suffix}-${VERSION}.tar.gz"
stage=4
get_file "contrail-controller-${suffix}-${VERSION}.tar.gz"
stage=5
get_file "contrail_debs-${VERSION}-${OPENSTACK_VERSION}.tgz"
cp "docker/contrail_debs-${VERSION}-${OPENSTACK_VERSION}.tgz" contrail_debs.tgz

stage=6

set_status "Setting up apt-repo."
# only this file is allowed to be run with sudo in the sandbox.
sudo $my_dir/../contrail/create-aptrepo.sh
set_status "Apt-repo was setup."

stage=7

set_status "Downloading repo.key"
repo_key=`curl -s http://$private_ip/ubuntu/repo.key`
repo_key=`echo "$repo_key" | awk '{printf("          %s\r", $0)}'`

set_status "Preparing bundle for deployment"
# change bundles' variables
JUJU_REPO="$cdir/contrail-charms"
BUNDLE="$cdir/bundle.yaml"
rm -f "$BUNDLE"
cp "$my_dir/bundle.yaml.template" "$BUNDLE"
sed -i -e "s/%SERIES%/$SERIES/m" $BUNDLE
sed -i -e "s/%OPENSTACK_ORIGIN%/$OPENSTACK_ORIGIN/m" $BUNDLE
sed -i -e "s/%PASSWORD%/$PASSWORD/m" $BUNDLE
sed -i -e "s|%JUJU_REPO%|$JUJU_REPO|m" $BUNDLE
sed -i -e "s|%REPO_IP%|$private_ip|m" $BUNDLE
sed -i -e "s|%REPO_KEY%|$repo_key|m" $BUNDLE
sed -i "s/\r/\n/g" $BUNDLE

set_status "Deploying bundle with Juju"
juju deploy $BUNDLE

stage=8
set_status "Attaching resource for controller"
juju attach contrail-controller contrail-controller="$cdir/docker/contrail-controller-${suffix}-${VERSION}.tar.gz"
stage=9
set_status "Attaching resource for analyticsdb"
juju attach contrail-analyticsdb contrail-analyticsdb="$cdir/docker/contrail-analyticsdb-${suffix}-${VERSION}.tar.gz"
stage=10
set_status "Attaching resource for analytics"
juju attach contrail-analytics contrail-analytics="$cdir/docker/contrail-analytics-${suffix}-${VERSION}.tar.gz"

stage=11

set_status "Configuring OpenStack services"
source "$my_dir/../common/functions"
source "$my_dir/../contrail/functions"
set_status "Detecting machines for OpenStack"
detect_machines
set_status "Re-configuring OpenStack public endpoints"
hack_openstack

# last stage is empty. just a mark how many stages here.
stage=12

reset_status

# TODO:
# next code is not ready for progress yet

log_info "Waiting for service start"
if ! wait_absence_status_for_services "executing|blocked|waiting" 39 ; then
  echo "ERROR: Some services went to error state"
  juju status --format tabular
  exit 1
fi
log_info "Waiting for service end"
juju status --format tabular


wget -t 2 -T 60 -q http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img &
pid=$!


log_info "source OpenStack credentials"
create_stackrc
source "$HOME/stackrc"

log_info "create virtual env and install openstack client"
rm -rf .venv
virtualenv .venv
source .venv/bin/activate
pip install -q python-openstackclient python-neutronclient twisted awscli 2>/dev/null

log_info "create image"
wait $pid
openstack image create --public --file cirros-0.3.4-x86_64-disk.img cirros

log_info "create public network"
openstack network create --external public --share
public_net_id=`openstack network show public -f value -c id`

log_info "create demo tenant"
openstack project create demo
log_info "add admin user to demo tenant"
openstack role add --project demo --user $OS_USERNAME admin

log_info "create router for demo project"
# openstack cli doesn't work with project argument in Mitaka
#openstack router create router-ext
neutron --os-project-name demo router-create router-ext
router_id=`openstack router show router-ext -f value -c id`
log_info "created router: $router_id"
log_info "attach external gateway for router"
openstack router set --external-gateway $public_net_id $router_id


# NOTE: try to avoid addresses with such last octet due to wide CIDR in openstack in case of its usage
# (try to use /27 or smaller (/27 or /28 or /29 or /30 only)
function get_cidr() {
  local ip=$1
  local mask="7"
  local cidr=""
  while [[ -z "$cidr" && $mask != "0" ]] ; do
    ((--mask))
    local rmask=$((8 - mask))
    local rmask_exp=$(( 2 ** rmask))
    local cidr=$((ip - ip % rmask_exp))
    if (( ip == cidr || ip == (cidr + 2) || ip == (cidr + rmask_exp - 1) )) ; then
      local cidr=""
    fi
  done
  echo $cidr/$((mask + 24))
}

# getting only one compute node. VM-s on other computes should be availabe via this compute by contrail overlay
log_info "detect compute for adding secondary ip-s"
compute=`juju status contrail-openstack-compute | grep -A 2 '^Machine' | awk '/started/ {print($1","$4)}' | head -1`
log_info "detected compute is $compute"
index=`echo "$compute" | cut -d , -f 1`
id=`echo "$compute" | cut -d , -f 2`
log_info "detect network interface id for instance $id"
ni_id=`aws ec2 describe-instances --instance-id $id --query 'Reservations[*].Instances[*].NetworkInterfaces[*].NetworkInterfaceId' --output text`
log_info "network interface is $ni_id"
log_info "add two secondary private addresses to this network interface of compute host"
aws ec2 assign-private-ip-addresses --network-interface-id $ni_id --secondary-private-ip-address-count 2
log_info "getting new addresses"
private_ips=(`aws ec2 describe-instances --instance-id $id --query 'Reservations[*].Instances[*].NetworkInterfaces[*].PrivateIpAddresses[*]' --output text | awk '/^False/{print $3}'`)
log_info "addresses are: ${private_ips[@]}"

for ip in ${private_ips[@]} ; do
  # TODO: detect interface for adding aliases
  juju ssh $index "sudo ifconfig eth0 add $ip up"
done
# here we have private_ips from one compute hosts which will be associated with new elastic ips

truncate -s 0 "$addresses_store_file"

subnets=''
forbidden_octets=",0,2,4,8,16,31,32,34,63,64,66,95,96,98,128,159,160,162,191,192,194,223,224,226,255,"
for i in {0..1} ; do
  log_info "allocate floating ip #$((i+1)) in amazon"
  ip=""
  for op in {1..5} ; do
    log_info "Attempt #$op to allocate suitable FIP"
    address_output=`aws ec2 allocate-address --domain vpc`
    ip=`echo "$address_output" | jq -r ".PublicIp"`
    ip_id=`echo "$address_output" | jq -r ".AllocationId"`
    ip_last_octet=`echo "$ip" | cut -d . -f 4`
    if ! echo "$forbidden_octets" | grep -q ",$ip_last_octet," ; then
      break
    fi
    # TODO: also here must be check that second cidr is not intersect with first
    ip=""
    aws ec2 release-address --allocation-id $ip_id
    sleep 2
  done
  if [ -z "$ip" ] ; then
    log_info "Can't allocate suitable address from Amazon"
    exit 1
  fi
  log_info "Allocated ip $ip"
  echo "${ip},${ip_id}" >> "$addresses_store_file"
  ip_first_octets=`echo "$ip" | cut -d . -f 1,2,3`
  ip_last_octet=`echo "$ip" | cut -d . -f 4`

  log_info "Trying to calculate CIDR"
  cidr=`get_cidr $ip_last_octet`
  if [ -z "$cidr" ] ; then
    log_info "Can't calculate CIDR for last octet $ip_last_octet of address $ip"
    exit 1
  fi
  full_cidr="${ip_first_octets}.${cidr}"
  subnets="$subnets $full_cidr"

  private_ip=${private_ips[$i]}
  if ! output=`aws ec2 associate-address --allocation-id $ip_id --network-interface-id $ni_id --private-ip-address $private_ip` ; then
    log_info "Can't associate address to network interface"
    echo "$output"
    exit 1
  fi

  log_info "add DNAT rules"
  juju ssh $index sudo iptables -t nat -A PREROUTING -d $private_ip/32 -j DNAT --to-destination $ip
  log_info "add SNAT rules"
  juju ssh $index sudo iptables -t nat -A POSTROUTING -s $ip/32 -j SNAT --to-source $private_ip

  log_info "create subnet in public network for allocated ip #$i"
  openstack subnet create --no-dhcp --network $public_net_id --subnet-range $full_cidr --gateway 0.0.0.0 public --allocation-pool start=$ip,end=$ip
done

log_info "provision VGW on compute host with subnets $subnets"
juju ssh $index sudo /opt/contrail/utils/provision_vgw_interface.py --oper create --interface vgw --subnets $subnets --routes 0.0.0.0/0 --vrf default-domain:admin:public:public

log_info "add rules to allow forwarding between vhost0 and vgw"
juju ssh $index sudo iptables -A FORWARD -i vhost0 -o vgw -j ACCEPT
juju ssh $index sudo iptables -A FORWARD -i vgw -o vhost0 -j ACCEPT

log_info "allow all traffic to compute node: $id"
open_port $index 0-65535 all
