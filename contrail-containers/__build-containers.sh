#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source $my_dir/functions

prepare_build_machine
# ip is located in /usr/sbin that is not in path...
export PATH=${PATH}:/usr/sbin

echo "INFO: Run setup-for-build  $(date)"

cd contrail-container-builder/containers
./setup-for-build.sh

echo "INFO: Run build  $(date)"

sudo -E ./build.sh || /bin/true
sudo docker images | grep "$CONTRAIL_VERSION"

echo "INFO: Build finished  $(date)"
