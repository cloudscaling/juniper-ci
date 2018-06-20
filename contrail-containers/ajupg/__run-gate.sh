#!/bin/bash -ex

mkdir -p /root/.ssh && cp /.ssh/* /root/.ssh/ && chown root:root /root/.ssh
cd /root

yum install -i iptables
iptables -S FORWARD | awk '/icmp/{print "iptables -D ",$2,$3,$4,$5,$6,$7,$8}' | bash

cd contrail-ansible-deployer
ansible-playbook -v -e orchestrator=none -e config_file=/root/contrail-ansible-deployer/instances.yaml playbooks/configure_instances.yml
ansible-playbook -v -e orchestrator=openstack -e config_file=/root/contrail-ansible-deployer/instances.yaml playbooks/install_contrail.yml
