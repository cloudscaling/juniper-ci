#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/../common/functions"
source "$my_dir/functions"

log_dir="$WORKSPACE/logs"
BUNDLE="$my_dir/openstack-contrail-amazon.yaml"

trap 'catch_errors_ce $LINENO' ERR EXIT
function catch_errors_ce() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

if [ "$DEPLOY_AS_HA_MODE" != 'false' ] ; then
  echo "ERROR: Deploy from the bundle doesn't support HA mode."
  exit 1
fi

# version 2
JUJU_REPO="$WORKSPACE/contrail-charms"

echo "---------------------------------------------------- From: $JUJU_REPO  Version: $VERSION"

# change bundles' variables
echo "INFO: Change variables in bundle..."
rm -f "$BUNDLE.tmp"
cp "$BUNDLE" "$BUNDLE.tmp"
BUNDLE="$BUNDLE.tmp"
sed -i -e "s/%SERIES%/$SERIES/m" $BUNDLE
sed -i -e "s/%OPENSTACK_ORIGIN%/$OPENSTACK_ORIGIN/m" $BUNDLE
sed -i -e "s/%PASSWORD%/$PASSWORD/m" $BUNDLE
sed -i -e "s|%JUJU_REPO%|$JUJU_REPO|m" $BUNDLE
sed -i -e "s|%USE_EXTERNAL_RABBITMQ%|false|m" $BUNDLE
sed -i -e "s|%AUTH_MODE%|$AAA_MODE|m" $BUNDLE
sed -i "s/\r/\n/g" $BUNDLE
cp $BUNDLE "$log_dir/"

echo "INFO: Deploy bundle $(date)"
juju-deploy-bundle $BUNDLE

echo "INFO: Detect machines $(date)"
detect_machines
cleanup_computes
echo "INFO: Set endpoints $(date)"
hack_openstack
echo "INFO: Apply SSL flag if set $(date)"
apply_ssl contrail

post_deploy

trap - ERR EXIT
