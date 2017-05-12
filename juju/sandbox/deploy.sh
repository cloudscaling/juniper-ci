#!/bin/bash -ex

if [[ "$HOME" == "" ]] ; then
  echo "ERROR: HOME variable must be set"
  exit 1
fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"


function log_info() {
  echo "$(date) INFO: $@"
}

function set_status() {
  log_info "$@"
}

function reset_status() {
  log_info "Waiting for deployment..."
}

set_status "start deploying..."

export VERSION=${VERSION:-'3073'}
export OPENSTACK_VERSION=${OPENSTACK_VERSION:-'mitaka'}
export CHARMS_VERSION=${CHARMS_VERSION:-'b6c43803c068b6ccbcbb12800ac0add384dcff3e'}
export SERIES=${SERIES:-'trusty'}
OPENSTACK_ORIGIN="cloud:${SERIES}-${OPENSTACK_VERSION}"
export PASSWORD=${PASSWORD:-'password'}

base_url='https://s3-us-west-2.amazonaws.com/contrailpkgs'
suffix='ubuntu14.04-4.0.0.0'

set_status "detecting instance details"
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
cd "$HOME"
cdir="$(pwd)"
log_info "working in the HOME directory = $HOME"

set_status "setting juju credentials"
$my_dir/_set-juju-creds.sh
set_status "bootstrapping juju"
juju --debug bootstrap --bootstrap-series=trusty aws amazon --config vpc-id=$vpc_id --config vpc-id-force=true

set_status "cloning contrail-charms repository at point $CHARMS_VERSION"
rm -rf contrail-charms
git clone https://github.com/Juniper/contrail-charms.git
cd contrail-charms
git checkout $CHARMS_VERSION
cd ..

# NOTE: next operations (downloading all archives) can take from 1 minute to 10 minutes or more.
# so now script doesn't delete/re-download archives if something with same file name is present.
mkdir -p docker

function get_file() {
  local f_name="$1"
  if [ ! -f "$fn" ] ; then
    set_status "downloading '$fn'"
    wget -nv "${base_url}/$fn" -O "docker/$fn"
  else
    set_status "'$fn' found. skipping downloading."
  fi
}

get_file "contrail-analytics-${suffix}-${VERSION}.tar.gz"
get_file "contrail-analyticsdb-${suffix}-${VERSION}.tar.gz"
get_file "contrail-controller-${suffix}-${VERSION}.tar.gz"

get_file "contrail_debs-${VERSION}-${OPENSTACK_VERSION}.tgz"
mv "contrail_debs-${VERSION}-${OPENSTACK_VERSION}.tgz" contrail_debs.tgz

set_status "Setting up apt-repo."
# only this file is allowed to be run with sudo in the sandbox.
sudo $my_dir/../contrail/create-aptrepo.sh
set_status "Apt-repo was setup."

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
set_status "Attaching resource for controller"
juju attach contrail-controller contrail-controller="$cdir/docker/contrail-controller-${suffix}-${VERSION}.tar.gz"
set_status "Attaching resource for analyticsdb"
juju attach contrail-analyticsdb contrail-analyticsdb="$cdir/docker/contrail-analyticsdb-${suffix}-${VERSION}.tar.gz"
set_status "Attaching resource for analytics"
juju attach contrail-analytics contrail-analytics="$cdir/docker/contrail-analytics-${suffix}-${VERSION}.tar.gz"

set_status "Configuring OpenStack services"
source "$my_dir/../common/functions"
source "$my_dir/../contrail/functions"
set_status "Detecting machines for OpenStack"
detect_machines
set_status "Re-configuring OpenStack public endpoints"
hack_openstack

reset_status
