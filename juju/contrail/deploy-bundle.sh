#!/bin/bash -e

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

# script needs to create machine for deploy packages before bundle start
# it can be moved to the bundle when charms will accept packages as resource
# or script will create apt-repo somewhere before (TODO)
# NOTE: it sets machines variables
prepare_machines


# change bundles' variables
echo "INFO: Change variables in bundle..."
rm -f "$BUNDLE.tmp"
cp "$BUNDLE" "$BUNDLE.tmp"
BUNDLE="$BUNDLE.tmp"
sed -i -e "s/%SERIES%/$SERIES/m" $BUNDLE
sed -i -e "s/%OPENSTACK_ORIGIN%/$OPENSTACK_ORIGIN/m" $BUNDLE
sed -i -e "s|%JUJU_REPO%|$JUJU_REPO|m" $BUNDLE

# script needs to change directory to local charms repository
cd contrail-charms
juju-deploy-bundle $BUNDLE
cd ..

juju-attach contrail-controller contrail-controller="$HOME/docker/$image_controller"
juju-attach contrail-analyticsdb contrail-analyticsdb="$HOME/docker/$image_analyticsdb"
juju-attach contrail-analytics contrail-analytics="$HOME/docker/$image_analytics"

post_deploy
