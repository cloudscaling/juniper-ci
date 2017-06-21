#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/../common/openstack/functions"

if [ -z "$WORKSPACE" ] ; then
  export WORKSPACE="$HOME"
fi

cd $WORKSPACE
source $WORKSPACE/overcloudrc
create_virtualenv
run_os_checks
