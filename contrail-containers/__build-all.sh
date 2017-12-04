#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source $my_dir/functions

prepare_build_machine

./contrail-build-poc/build.sh
