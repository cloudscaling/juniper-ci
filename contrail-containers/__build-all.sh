#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source $my_dir/functions

prepare_build_machine
# ip is located in /usr/sbin that is not in path...
export PATH=${PATH}:/usr/sbin

./contrail-build-poc/build.sh
