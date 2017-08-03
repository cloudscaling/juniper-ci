#!/bin/bash -e

DEBUG=${DEBUG:-0}

if (( DEBUG == 1 )) ; then set -x ; fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [ -z "$WORKSPACE" ] ; then
  export WORKSPACE="$HOME"
fi

for mid in `nova list | awk '/-novacompute-/{print $12}'` ; do
  mip="`echo $mid | cut -d '=' -f 2`"
  ssh heat-admin@$mip sudo yum install -y sshpass
done

cd $WORKSPACE
source "$my_dir/../common/openstack/functions"
create_virtualenv
run_os_checks
