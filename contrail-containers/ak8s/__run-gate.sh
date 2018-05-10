#!/bin/bash -ex

mkdir -p /root/.ssh && cp /.ssh/* /root/.ssh/ && chown root:root /root/.ssh
cd /root

function save_logs() {
  mkdir -p /root/logs/kolla
  cp -r /root/contrail-kolla-ansible/etc/kolla/globals.yml /root/logs/kolla/
  cp -r /root/contrail-kolla-ansible/ansible/host_vars /root/logs/kolla/
  chmod -R a+rw /root/logs/kolla
}

trap 'catch_errors $LINENO' ERR
function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR
  set +e
  save_logs
  exit $exit_code
}

cd contrail-ansible-deployer
ansible-playbook -v -e config_file=/root/contrail-ansible-deployer/instances.yaml -e kolla_dir=/tmp playbooks/configure_instances.yml
ansible-playbook -v -e orchestrator=openstack -e config_file=/root/contrail-ansible-deployer/instances.yaml playbooks/install_contrail.yml

trap - ERR
save_logs
