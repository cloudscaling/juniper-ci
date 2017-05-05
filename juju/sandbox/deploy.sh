#!/bin/bash -e

SERIES='trusty'
OPENSTACK_ORIGIN="cloud:${SERIES}-${OPENSTACK_VERSION}"

mac_url='http://169.254.169.254/latest/meta-data/network/interfaces/macs/'
mac=`curl -s $mac_url`
vpc_id=`curl -s ${mac_url}${mac}vpc-id`
subnet_id=`curl -s ${mac_url}${mac}subnet-id`
private_ip=`curl -s ${mac_url}${mac}local-ipv4s`

./juniper-ci/juju/sandbox/_set-juju-creds.sh
juju --debug bootstrap --bootstrap-series=trusty aws amazon --config vpc-id=$vpc_id --config vpc-id-force=true

rm -rf contrail-charms
git clone https://github.com/Juniper/contrail-charms.git
cd contrail-charms
git checkout $CHARMS_VERSION
cd ..

mkdir -p docker
cd docker
base_name='https://s3-us-west-2.amazonaws.com/contrailpkgs'
suffix='ubuntu14.04-4.0.0.0'
wget -nv ${base_name}/contrail-analytics-${suffix}-${VERSION}.tar.gz
wget -nv ${base_name}/contrail-analyticsdb-${suffix}-${VERSION}.tar.gz
wget -nv ${base_name}/contrail-controller-${suffix}-${VERSION}.tar.gz
cd ..

wget -nv https://s3-us-west-2.amazonaws.com/contrailpkgs/contrail_debs-${VERSION}-${OPENSTACK_VERSION}.tgz -O contrail_debs.tgz
./juniper-ci/juju/contrail/create-aptrepo.sh

repo_key=`curl -s http://$private_ip/ubuntu/repo.key`
repo_key=`echo "$repo_key" | awk '{printf("          %s\r", $0)}'`

# change bundles' variables
JUJU_REPO="$(pwd)/contrail-charms"
BUNDLE="./bundle.yaml"
rm -f "$BUNDLE"
cp "juniper-ci/juju/sandbox/bundle.yaml.template" "$BUNDLE"
sed -i -e "s/%SERIES%/$SERIES/m" $BUNDLE
sed -i -e "s/%OPENSTACK_ORIGIN%/$OPENSTACK_ORIGIN/m" $BUNDLE
sed -i -e "s|%JUJU_REPO%|$JUJU_REPO|m" $BUNDLE
sed -i -e "s|%REPO_IP%|$private_ip|m" $BUNDLE
sed -i -e "s|%REPO_KEY%|$repo_key|m" $BUNDLE
sed -i "s/\r/\n/g" $BUNDLE

juju deploy $BUNDLE
juju attach contrail-controller contrail-controller="./docker/contrail-controller-${suffix}-${VERSION}.tar.gz"
juju attach contrail-analyticsdb contrail-analyticsdb="./docker/contrail-analyticsdb-${suffix}-${VERSION}.tar.gz"
juju attach contrail-analytics contrail-analytics="./docker/contrail-analytics-${suffix}-${VERSION}.tar.gz"

source ./juniper-ci/juju/common/functions
source ./juniper-ci/juju/contrail/functions
detect_machines
hack_openstack
