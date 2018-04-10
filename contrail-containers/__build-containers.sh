#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

# ip is located in /usr/sbin that is not in path...
export PATH=${PATH}:/usr/sbin

echo "INFO: Run setup-for-build  $(date)"

cd contrail-container-builder/containers

./setup-for-build.sh
echo "INFO: Run build  $(date)"
sudo -E ./build.sh || /bin/true

sudo docker images | grep "$CONTRAIL_VERSION"

# cause we use this machine for cloud after build process then we need to free port 80
sudo systemctl stop lighttpd.service
sudo systemctl disable lighttpd.service

echo "INFO: Build finished  $(date)"
