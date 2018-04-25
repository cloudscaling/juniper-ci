#!/bin/bash -ex

mkdir -p /root/.ssh && cp /.ssh/* /root/.ssh/ && chown root:root /root/.ssh
cd /root

# clone contrail-kolla-ansible by here to avoid problems with new files created under root account
# clone it to be able to apply patchset
git clone -b contrail/ocata https://github.com/Juniper/contrail-kolla-ansible.git
if [[ -n "$KOLLA_PATCHSET_CMD" ]]; then
  pushd contrail-kolla-ansible
  /bin/bash -c "$KOLLA_PATCHSET_CMD"
  popd
fi

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
ansible-playbook -v -i inventory/ -e config_file=/root/contrail-ansible-deployer/instances.yaml -e kolla_dir=/tmp playbooks/configure_instances.yml
ansible-playbook -v -i inventory/ -e orchestrator=openstack -e config_file=/root/contrail-ansible-deployer/instances.yaml playbooks/install_contrail.yml

trap - ERR
save_logs
