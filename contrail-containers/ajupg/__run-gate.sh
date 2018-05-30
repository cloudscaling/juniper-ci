#!/bin/bash -ex

mkdir -p /root/.ssh && cp /.ssh/* /root/.ssh/ && chown root:root /root/.ssh
cd /root

cd contrail-ansible-deployer
ansible-playbook -v -e config_file=/root/contrail-ansible-deployer/instances.yaml playbooks/configure_instances.yml
ansible-playbook -v -e config_file=/root/contrail-ansible-deployer/instances.yaml playbooks/install_contrail.yml
