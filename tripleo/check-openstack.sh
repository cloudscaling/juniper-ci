#!/bin/bash -e

DEBUG=${DEBUG:-0}

if (( DEBUG == 1 )) ; then set -x ; fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [ -z "$WORKSPACE" ] ; then
  export WORKSPACE="$HOME"
fi

source ${WORKSPACE}/stackrc
node_name_regexp='compute'
if [[ "$DPDK" == 'true' ]]; then
  node_name_regexp='dpdk'
fi
for mid in `nova list | grep "$node_name_regexp" |  awk '{print $12}'` ; do
  mip="`echo $mid | cut -d '=' -f 2`"
  ssh heat-admin@$mip sudo yum install -y sshpass
done

cd $WORKSPACE
source ${WORKSPACE}/overcloudrc
source "$my_dir/../common/openstack/functions"
create_virtualenv
prep_os_checks
run_os_checks
