#!/bin/bash -e

my_file="${BASH_SOURCE[0]}"
my_dir="$(dirname $my_file)"
source "$my_dir/functions"

trap 'catch_errors_ce $LINENO' ERR EXIT
function catch_errors_ce() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

# for simple setup you can setup MASQUERADING on compute hosts?
#juju-ssh $m2 "sudo iptables -t nat -A POSTROUTING -o vhost0 -j MASQUERADE"
#juju-ssh $m3 "sudo iptables -t nat -A POSTROUTING -o vhost0 -j MASQUERADE"

if [ -z "$WORKSPACE" ] ; then
  export WORKSPACE="$HOME"
fi

# prepare environment for common openstack functions
OPENSTACK_VERSION="$VERSION"
SSH_CMD="juju-ssh"

for mch in `get_machines_index_by_service nova-compute` ; do
  juju-ssh $mch sudo apt-get -y install sshpass &>/dev/null
done

source "$my_dir/functions-openstack"

cd $WORKSPACE
create_stackrc
source $WORKSPACE/stackrc
create_virtualenv

run_os_checks

trap - ERR EXIT
