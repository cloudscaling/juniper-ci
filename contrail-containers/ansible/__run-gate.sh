#!/bin/bash -ex

mkdir -p /root/.ssh && cp /.ssh/* /root/.ssh/ && chown root:root /root/.ssh
cd /root/contrail-ansible-deployer
ansible-playbook -v -i inventory/ -e config_file=/root/contrail-ansible-deployer/instances.yaml playbooks/configure_instances.yml
ansible-playbook -v -i inventory/ -e orchestrator=openstack -e config_file=/root/contrail-ansible-deployer/instances.yaml playbooks/install_contrail.yml
