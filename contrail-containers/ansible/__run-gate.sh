#!/bin/bash -x

mkdir -p /root/.ssh && cp /.ssh/* /root/.ssh/ && chown root:root /root/.ssh
cd /root/contrail-ansible-deployer

ansible-playbook -v -i inventory/ -e config_file=/root/contrail-ansible-deployer/instances.yaml playbooks/configure_instances.yml || ret=1
cp -r /etc/kolla /root/logs/
if [[ "$ret" == '1' ]]; then
  exit 1
fi

ansible-playbook -v -i inventory/ -e orchestrator=openstack -e config_file=/root/contrail-ansible-deployer/instances.yaml playbooks/install_contrail.yml || ret=1
# copy needed info to /root/logs
if [[ "$ret" == '1' ]]; then
  exit 1
fi
