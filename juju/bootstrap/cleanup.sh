#!/bin/bash

[ ! -d ~/bootstrap/openstack/.venv/bin ] && echo no any .env found && exit

cd ~/bootstrap/openstack
source .venv/bin/activate
. ~/bootstrap/config/openrc.sh

# destroy servers

openstack server delete cont
openstack server delete work
openstack server delete half

# and other openstack artifacts

openstack flavor delete cont
openstack flavor delete work
openstack flavor delete half

openstack keypair delete localkey
