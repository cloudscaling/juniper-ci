#!/bin/bash

### Before start

# fix /etc/hosts
# copy all files in ~/bootstrap directory on first Openstack VM

### Parameters

# Contrail

export CONTROLLER_NODES=10.0.12.20

# Openstack
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=password
export OS_KEYSTONE_IP=10.0.12.105
export OS_KEYSTONE_PORT=5000

# Initial steps

[ ! -d ~/bootstrap ] && echo no bootstrap files && exit

mkdir ~/bootstrap/openstack
mkdir ~/bootstrap/config

sudo apt-get update
sudo apt-get install -y jq

[ ! -f ~/.ssh/id_rsa ] && ssh-keygen -t rsa -b 2048 -N '' -f ~/.ssh/id_rsa

# Install Openstack API

sudo apt-get install -y python-dev python-pip
pip install virtualenv

mkdir ~/bootstrap/openstack
cd ~/bootstrap/openstack
virtualenv .venv
source .venv/bin/activate
pip install python-openstackclient

envsubst < ~/bootstrap/template/openrc.sh > ~/bootstrap/config/openrc.sh
chmod 0755 ~/bootstrap/config/openrc.sh
. ~/bootstrap/config/openrc.sh

# Get current VM info

serverip=$(hostname -i)
serverid=$(openstack server list -f json --ip $serverip | jq .[0].ID -r)
[ "serverid" == "null" ] && echo no server detected && exit
serverobj=$(openstack server show $serverid -f json)

projectid=$(echo $serverobj | jq .project_id -r)

addresses=$(echo $serverobj | jq .addresses -r)
export networkname=${addresses%=*}
networkid=$(openstack network show $networkname -f json | jq .id -r)

serverimage=$(echo $serverobj | jq .image -r)
serverimage=${serverimage#* (}
imageid=${serverimage%)*}

echo Server ID $serverid
echo Project ID $projectid
echo Network ID $networkid Name $networkname
echo Image ID $imageid

# Openstack objects

openstack flavor create --disk 10 --vcpus 1 --ram 2048 cont
openstack flavor create --disk 10 --vcpus 1 --ram 4096 work
openstack flavor create --disk 10 --vcpus 1 --ram 512 half

openstack keypair create --public-key ~/.ssh/id_rsa.pub localkey -f json

# Launch VMs

cont_id=$(openstack server create --image $imageid --flavor cont --key-name localkey --nic net-id=$networkid cont -f json | jq .id -r)
work_id=$(openstack server create --image $imageid --flavor work --key-name localkey --nic net-id=$networkid work -f json | jq .id -r)
half_id=$(openstack server create --image $imageid --flavor half --key-name localkey --nic net-id=$networkid half -f json | jq .id -r)

echo Test servers are created: $cont_id $work_id $half_id

# waiting server's sshd
sleep 120

cont_addr=$(openstack server show $cont_id -f json | jq .addresses -r)
cont_ip=${cont_addr#*=}
work_addr=$(openstack server show $work_id -f json | jq .addresses -r)
work_ip=${work_addr#*=}
half_addr=$(openstack server show $half_id -f json | jq .addresses -r)
half_ip=${half_addr#*=}

echo Test servers IPs: $cont_ip $work_ip $half_ip

# Get charms sources

cd ~
rm -rf ~/contrail-charms
git clone https://github.com/Juniper/contrail-charms
cd ~/contrail-charms
git checkout R5

envsubst < ~/bootstrap/template/nested-mode-test.yaml > ~/contrail-charms/examples/nested-mode-test.yaml

# check connectivity ### TODO remove this step

exit

# Install juju and add machines

sudo snap install juju --classic

juju bootstrap manual/ubuntu@$cont_ip cont
juju add-machine ssh:ubuntu@$work_ip
juju add-machine ssh:ubuntu@$half_ip

cd ~/contrail-charms
juju deploy ./examples/nested-mode-test.yaml --map-machines=existing
