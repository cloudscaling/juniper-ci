#!/bin/bash -ex

iface=`ip -4 route list 0/0 | awk '{ print $5; exit }'`
local_ip=`ip addr | grep $iface | grep 'inet ' | awk '{print $2}' | cut -d '/' -f 1`
sudo cp -f /etc/hosts /etc/hosts.bak
sudo sed -i "/$(hostname)/d" /etc/hosts
echo "$local_ip $(hostname)" | sudo tee -a /etc/hosts


export CONTRAIL_VERSION=4.0.2.0-35
git clone ${DOCKER_CONTRAIL_URL:-https://github.com/ftersin/docker-contrail-4}
cd docker-contrail-4/containers
./setup-for-build.sh
sudo -E ./build.sh || /bin/true
sudo docker images | grep "0-35"
sudo -E ./build.sh || /bin/true
sudo docker images | grep "0-35"
