#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [ -z "$WORKSPACE" ] ; then
  export WORKSPACE="$HOME"
fi
cd $WORKSPACE

source $WORKSPACE/overcloudrc
source "$my_dir/../common/openstack/functions"
create_virtualenv
run_os_checks
