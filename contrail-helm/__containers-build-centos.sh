#!/bin/bash -ex

# ip is located in /usr/sbin that is not in path...
export PATH=${PATH}:/usr/sbin

sudo yum install -y epel-release
sudo yum install -y mc git wget ntp httpd iptables iproute nmap

iface=`ip -4 route list 0/0 | awk '{ print $5; exit }'`
local_ip=`ip addr | grep $iface | grep 'inet ' | awk '{print $2}' | cut -d '/' -f 1`
sudo cp -f /etc/hosts /etc/hosts.bak
sudo sed -i "/$(hostname)/d" /etc/hosts
echo "$local_ip $(hostname)" | sudo tee -a /etc/hosts
sudo sed -i "/$(hostname -s)/d" /etc/hosts
echo "$local_ip $(hostname -s)" | sudo tee -a /etc/hosts


git clone ${DOCKER_CONTRAIL_URL:-https://github.com/cloudscaling/docker-contrail-4}
cd docker-contrail-4/containers
./setup-for-build.sh
sudo -E ./build.sh || /bin/true
sudo docker images | grep "0-35"
