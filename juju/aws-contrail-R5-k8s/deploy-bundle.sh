#!/bin/bash -eE

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/../common/functions"
source "$my_dir/functions"

log_dir="$WORKSPACE/logs"
BUNDLE="$my_dir/bundle.yaml"

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
python "$my_dir/../common/jinja2_render.py" <"$my_dir/bundle.yaml.tmpl" >"$my_dir/bundle.yaml"
cp "$my_dir/bundle.yaml" "$log_dir/"

echo "INFO: Deploy bundle $(date)"
juju-deploy-bundle "$my_dir/bundle.yaml"

echo 'INFO: Fix /etc/hosts'
for node in $(get_machines_index_by_service kubernetes-worker); do
  echo "INFO: node: $node"
  wait_for_machines $node
  fix_aws_hostname $node
done
for node in $(get_machines_index_by_service kubernetes-master); do
  echo "INFO: node: $node"
  wait_for_machines $node
  fix_aws_hostname $node
done

# wait a bit to avoid catching errors with apt-get install
sleep 120
# and then wait for result
post_deploy

trap - ERR EXIT
