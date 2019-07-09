#!/bin/bash -eE

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/../common/functions"
source "$my_dir/functions"

log_dir="$WORKSPACE/logs"
BUNDLE="$my_dir/kubernetes-contrail-amazon.yaml"

trap 'catch_errors_ce $LINENO' ERR EXIT
function catch_errors_ce() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

# version 2
export JUJU_REPO="$WORKSPACE/contrail-charms"

echo "---------------------------------------------------- From: $JUJU_REPO  Version: $VERSION"

# change bundles' variables
echo "INFO: Change variables in bundle..."
envsubst <${BUNDLE}.tmpl >$BUNDLE
#sed -i "s/\r/\n/g" $BUNDLE
cp $BUNDLE "$log_dir/"

echo "INFO: Deploy bundle $(date)"
juju-deploy-bundle $BUNDLE

echo "INFO: Detect machines $(date)"
#detect_machines

echo 'DBG: Fix /etc/hosts'
for node in $(get_machines_index_by_service kubernetes-worker); do
  echo "DBG, node: $node"
  fix_aws_hostname $node
  juju-ssh $node sudo docker restart vrouter_vrouter-agent_1
done

cleanup_computes
#echo "INFO: Set endpoints $(date)"
#hack_openstack
#echo "INFO: Apply SSL flag if set $(date)"
#apply_ssl contrail

# wait a bit to avoid catching errors with apt-get install
sleep 120
# and then wait for result
post_deploy

trap - ERR EXIT
