#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/../common/functions"
source "$my_dir/functions"

BUNDLE="$my_dir/openstack-contrail-amazon.yaml"

trap 'catch_errors_ce $LINENO' ERR EXIT
function catch_errors_ce() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

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
repo_ip=`get-machine-ip-by-number $mrepo`
repo_key=`curl -s http://$repo_ip/ubuntu/repo.key`
repo_key=`echo "$repo_key" | awk '{printf("          %s\r", $0)}'`

# change bundles' variables
echo "INFO: Change variables in bundle..."
rm -f "$BUNDLE.tmp"
cp "$BUNDLE" "$BUNDLE.tmp"
BUNDLE="$BUNDLE.tmp"
sed -i -e "s/%SERIES%/$SERIES/m" $BUNDLE
sed -i -e "s/%OPENSTACK_ORIGIN%/$OPENSTACK_ORIGIN/m" $BUNDLE
sed -i -e "s/%PASSWORD%/$PASSWORD/m" $BUNDLE
sed -i -e "s|%JUJU_REPO%|$JUJU_REPO|m" $BUNDLE
sed -i -e "s|%REPO_IP%|$repo_ip|m" $BUNDLE
sed -i -e "s|%REPO_KEY%|$repo_key|m" $BUNDLE
if [ "$USE_EXTERNAL_RABBITMQ" == 'true' ]; then
  sed -i -e "s|%USE_EXTERNAL_RABBITMQ%|true|m" $BUNDLE
else
  sed -i -e "s|%USE_EXTERNAL_RABBITMQ%|false|m" $BUNDLE
fi
sed -i "s/\r/\n/g" $BUNDLE

echo "INFO: Deploy bundle $(date)"
juju-deploy-bundle $BUNDLE

if [ "$USE_EXTERNAL_RABBITMQ" == 'true' ]; then
  juju-add-relation "contrail-controller" "rabbitmq-server:amqp"
fi

echo "INFO: Set endpoints $(date)"
detect_machines
hack_openstack
echo "INFO: Apply SSL flag if set $(date)"
apply_ssl

echo "INFO: Attach contrail-controller container $(date)"
juju-attach contrail-controller contrail-controller="$HOME/docker/$image_controller"
echo "INFO: Attach contrail-analyticsdb container $(date)"
juju-attach contrail-analyticsdb contrail-analyticsdb="$HOME/docker/$image_analyticsdb"
echo "INFO: Attach contrail-analytics container $(date)"
juju-attach contrail-analytics contrail-analytics="$HOME/docker/$image_analytics"

post_deploy

trap - ERR EXIT
