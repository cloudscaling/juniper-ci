#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/../common/functions"
source "$my_dir/functions"

BUNDLE="$my_dir/openstack-contrail-amazon.yaml"

# it also sets variables with names
check_containers

if [ "$DEPLOY_AS_HA_MODE" != 'false' ] ; then
  echo "ERROR: Deploy from the bundle doesn't support HA mode."
  exit 1
fi

jver="$(juju-version)"
deploy_from=${1:-github}   # Place where to get charms - github or charmstore
if [[ "$deploy_from" == github ]] ; then
  if [[ "$jver" == 1 ]] ; then
    exit 1
  else
    # version 2
    JUJU_REPO="$WORKSPACE/contrail-charms"
  fi
else
  # deploy_from=charmstore
  echo "ERROR: Deploy from charmstore is not supported yet"
  exit 1
fi

echo "---------------------------------------------------- From: $JUJU_REPO  Version: $VERSION"

prepare_repo
repo_ip=`get-machine-ip-by-number $m0`
repo_key=`curl http://$repo_ip/repo.key`
repo_key=`echo "$repo_key" | awk '{printf("          %s\r", $0)}'`

# change bundles' variables
echo "INFO: Change variables in bundle..."
rm -f "$BUNDLE.tmp"
cp "$BUNDLE" "$BUNDLE.tmp"
BUNDLE="$BUNDLE.tmp"
sed -i -e "s/%SERIES%/$SERIES/m" $BUNDLE
sed -i -e "s/%OPENSTACK_ORIGIN%/$OPENSTACK_ORIGIN/m" $BUNDLE
sed -i -e "s|%JUJU_REPO%|$JUJU_REPO|m" $BUNDLE
sed -i -e "s|%REPO_IP%|$repo_ip|m" $BUNDLE
sed -i -e "s|%REPO_KEY%|$repo_key|m" $BUNDLE
sed -i "s/\r/\n/g" $BUNDLE

# script needs to change directory to local charms repository
cd contrail-charms
juju-deploy-bundle $BUNDLE
cd ..

juju-attach contrail-controller contrail-controller="$HOME/docker/$image_controller"
juju-attach contrail-analyticsdb contrail-analyticsdb="$HOME/docker/$image_analyticsdb"
juju-attach contrail-analytics contrail-analytics="$HOME/docker/$image_analytics"

post_deploy
