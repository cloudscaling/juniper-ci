#!/bin/bash -e

DEBUG=${DEBUG:-0}

if (( DEBUG == 1 )) ; then set -x ; fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [ -z "$WORKSPACE" ] ; then
  export WORKSPACE="$HOME"
fi

cd $WORKSPACE
source "$my_dir/../common/openstack/functions"
create_virtualenv
run_os_checks
