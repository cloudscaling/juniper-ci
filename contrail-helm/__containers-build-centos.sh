#!/bin/bash -ex

# ip is located in /usr/sbin that is not in path...
export PATH=${PATH}:/usr/sbin

sudo yum install -y epel-release
sudo yum install -y mc git wget ntp iptables iproute

git clone ${DOCKER_CONTRAIL_URL:-https://github.com/cloudscaling/docker-contrail-4}
cd docker-contrail-4/containers
./setup-for-build.sh
sudo -E ./build.sh || /bin/true
sudo docker images | grep "$CONTRAIL_VERSION"
