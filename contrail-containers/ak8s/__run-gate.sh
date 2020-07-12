#!/bin/bash -eEx

mkdir -p /root/.ssh && cp /.ssh/* /root/.ssh/ && chown root:root /root/.ssh
cd /root

cd tf-ansible-deployer
cat >>ansible.cfg <<EOF
[ssh_connection]
ssh_args = -o ControlMaster=no
EOF
ansible-playbook -v -e orchestrator=kubernetes -e config_file=/root/tf-ansible-deployer/instances.yaml playbooks/configure_instances.yml
ansible-playbook -v -e orchestrator=kubernetes -e config_file=/root/tf-ansible-deployer/instances.yaml playbooks/install_k8s.yml
ansible-playbook -v -e orchestrator=kubernetes -e config_file=/root/tf-ansible-deployer/instances.yaml playbooks/install_contrail.yml
