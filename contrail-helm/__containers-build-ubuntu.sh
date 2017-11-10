#!/bin/bash -ex

sudo apt-get -y update && sudo apt-get -y upgrade
sudo apt-get install -y --no-install-recommends mc git wget ntp

git clone ${DOCKER_CONTRAIL_URL:-https://github.com/cloudscaling/docker-contrail-4}
cd docker-contrail-4/containers
./setup-for-build.sh
sudo -E ./build.sh || /bin/true
sudo docker images | grep "$CONTRAIL_VERSION"
