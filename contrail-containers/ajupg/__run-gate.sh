#!/bin/bash -eEx

mkdir -p /root/.ssh && cp /.ssh/* /root/.ssh/ && chown root:root /root/.ssh
cd /root

yum install -y iptables
iptables -S FORWARD | awk '/icmp/{print "iptables -D ",$2,$3,$4,$5,$6,$7,$8}' | bash

cd contrail-ansible-deployer
cat >>ansible.cfg <<EOF
[ssh_connection]
ssh_args = -o ControlMaster=no
EOF
ansible-playbook -v -e orchestrator=none -e config_file=/root/contrail-ansible-deployer/instances.yaml playbooks/configure_instances.yml
ansible-playbook -v -e orchestrator=openstack -e config_file=/root/contrail-ansible-deployer/instances.yaml playbooks/install_contrail.yml
