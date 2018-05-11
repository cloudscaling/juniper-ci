#!/bin/bash -ex

mkdir -p /root/.ssh && cp /.ssh/* /root/.ssh/ && chown root:root /root/.ssh
cd /root

function save_logs() {
  :
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
ansible-playbook -v -e config_file=/root/contrail-ansible-deployer/instances.yaml playbooks/configure_instances.yml
ansible-playbook -v -e orchestrator=kubernetes -e config_file=/root/contrail-ansible-deployer/instances.yaml playbooks/install_contrail.yml

trap - ERR
save_logs
