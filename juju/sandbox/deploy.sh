#!/bin/bash -e

if [[ "$HOME" == "" ]] ; then
  echo "ERROR: HOME variable must be set"
  exit 1
fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

export VERSION=${VERSION:-'3073'}
export OPENSTACK_VERSION=${OPENSTACK_VERSION:-'mitaka'}
export CHARMS_VERSION=${CHARMS_VERSION:-'b6c43803c068b6ccbcbb12800ac0add384dcff3e'}
export SERIES=${SERIES:-'trusty'}
OPENSTACK_ORIGIN="cloud:${SERIES}-${OPENSTACK_VERSION}"

base_name='https://s3-us-west-2.amazonaws.com/contrailpkgs'

mac_url='http://169.254.169.254/latest/meta-data/network/interfaces/macs/'
mac=`curl -s $mac_url`
vpc_id=`curl -s ${mac_url}${mac}vpc-id`
subnet_id=`curl -s ${mac_url}${mac}subnet-id`
private_ip=`curl -s ${mac_url}${mac}local-ipv4s`

# change directory to working directory
cd "$HOME"
cdir="$(pwd)"

$my_dir/_set-juju-creds.sh
juju --debug bootstrap --bootstrap-series=trusty aws amazon --config vpc-id=$vpc_id --config vpc-id-force=true

rm -rf contrail-charms
git clone https://github.com/Juniper/contrail-charms.git
cd contrail-charms
git checkout $CHARMS_VERSION
cd ..

# NOTE: this operation (downloading all archives) can take from 1 minute to 10 minutes or more.
# so now script doesn't delete/re-download archives if something with same file name is present.
mkdir -p docker
cd docker
suffix='ubuntu14.04-4.0.0.0'
if [ ! -f "${base_name}/contrail-analytics-${suffix}-${VERSION}.tar.gz" ] ; then
  wget -nv "${base_name}/contrail-analytics-${suffix}-${VERSION}.tar.gz"
fi
if [ ! -f "${base_name}/contrail-analyticsdb-${suffix}-${VERSION}.tar.gz" ] ; then
  wget -nv "${base_name}/contrail-analyticsdb-${suffix}-${VERSION}.tar.gz"
fi
if [ ! -f "${base_name}/contrail-controller-${suffix}-${VERSION}.tar.gz" ] ; then
  wget -nv "${base_name}/contrail-controller-${suffix}-${VERSION}.tar.gz"
fi
cd ..

if [ ! -f contrail_debs.tgz ] ; then
  wget -nv "${base_name}/contrail_debs-${VERSION}-${OPENSTACK_VERSION}.tgz" -O contrail_debs.tgz
fi
# only this file is allowed to be run with sudo in the sandbox.
sudo $my_dir/../contrail/create-aptrepo.sh

rm repo.key
repo_key=`curl -s http://$private_ip/ubuntu/repo.key`
repo_key=`echo "$repo_key" | awk '{printf("          %s\r", $0)}'`

# change bundles' variables
JUJU_REPO="$cdir/contrail-charms"
BUNDLE="$cdir/bundle.yaml"
rm -f "$BUNDLE"
cp "$my_dir/bundle.yaml.template" "$BUNDLE"
sed -i -e "s/%SERIES%/$SERIES/m" $BUNDLE
sed -i -e "s/%OPENSTACK_ORIGIN%/$OPENSTACK_ORIGIN/m" $BUNDLE
sed -i -e "s|%JUJU_REPO%|$JUJU_REPO|m" $BUNDLE
sed -i -e "s|%REPO_IP%|$private_ip|m" $BUNDLE
sed -i -e "s|%REPO_KEY%|$repo_key|m" $BUNDLE
sed -i "s/\r/\n/g" $BUNDLE

juju deploy $BUNDLE
juju attach contrail-controller contrail-controller="$cdir/docker/contrail-controller-${suffix}-${VERSION}.tar.gz"
juju attach contrail-analyticsdb contrail-analyticsdb="$cdir/docker/contrail-analyticsdb-${suffix}-${VERSION}.tar.gz"
juju attach contrail-analytics contrail-analytics="$cdir/docker/contrail-analytics-${suffix}-${VERSION}.tar.gz"

source "$my_dir/../common/functions"
source "$my_dir/../contrail/functions"
detect_machines
hack_openstack
