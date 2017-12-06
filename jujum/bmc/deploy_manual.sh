#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/functions"
source "$my_dir/../common/functions"

trap 'catch_errors_ce $LINENO' ERR EXIT
function catch_errors_ce() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

# version 2
comp1_ip=`get_kvm_machine_ip ${job_prefix}_os_comp_1_mac`
comp1=`juju status | grep $comp1_ip | awk '{print $1}'`
echo "INFO: compute 1: $comp1 / $comp1_ip"
comp2_ip=`get_kvm_machine_ip ${job_prefix}_os_comp_2_mac`
comp2=`juju status | grep $comp2_ip | awk '{print $1}'`
echo "INFO: compute 2: $comp2 / $comp2_ip"

cont0_ip=`get_kvm_machine_ip ${job_prefix}_os_cont_0_mac`
cont0=`juju status | grep $cont0_ip | awk '{print $1}'`
echo "INFO: controller 0 (OpenStack): $cont0 / $cont0_ip"

net1_ip=`get_kvm_machine_ip ${job_prefix}_os_net_1_mac`
net1=`juju status | grep $net1_ip | awk '{print $1}'`
echo "INFO: network 1: $net1 / $net1_ip"
net2_ip=`get_kvm_machine_ip ${job_prefix}_os_net_2_mac`
net2=`juju status | grep $net2_ip | awk '{print $1}'`
echo "INFO: network 1: $net2 / $net2_ip"
net3_ip=`get_kvm_machine_ip ${job_prefix}_os_net_3_mac`
net3=`juju status | grep $net3_ip | awk '{print $1}'`
echo "INFO: network 1: $net3 / $net3_ip"

# OpenStack base

echo "INFO: Deploy all $(date)"
juju-deploy cs:$SERIES/ntp

juju-deploy cs:$SERIES/rabbitmq-server --to lxd:$cont0
juju-deploy cs:$SERIES/percona-cluster mysql --to lxd:$cont0
juju-set mysql "root-password=$PASSWORD" "max-connections=1500"

juju-deploy cs:$SERIES/openstack-dashboard --to lxd:$cont0
juju-set openstack-dashboard "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose openstack-dashboard

juju-deploy cs:$SERIES/nova-cloud-controller --to lxd:$cont0
juju-set nova-cloud-controller "console-access-protocol=novnc" "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose nova-cloud-controller

juju-deploy cs:$SERIES/glance --to lxd:$cont0
juju-set glance "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose glance

juju-deploy cs:$SERIES/keystone --to lxd:$cont0
juju-set keystone "admin-password=$PASSWORD" "admin-role=admin" "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose keystone

juju-deploy cs:$SERIES/nova-compute --to $comp1
juju-add-unit nova-compute --to $comp2
juju-set nova-compute "debug=true" "openstack-origin=$OPENSTACK_ORIGIN" "virt-type=kvm" "enable-resize=True" "enable-live-migration=True" "migration-auth-type=ssh"

# Neutron
juju-deploy cs:$SERIES/neutron-api --to lxd:$cont0
juju-set neutron-api "debug=true" "openstack-origin=$OPENSTACK_ORIGIN" "enable-dvr=true"
juju-set nova-cloud-controller "network-manager=Neutron"
juju-expose neutron-api
juju-deploy neutron-openvswitch

juju-deploy neutron-gateway --to $net1
juju-add-unit neutron-gateway --to $net2
juju-add-unit neutron-gateway --to $net3

detect_machines
wait_for_machines $m1 $m2 $m3 $m4 $m5 $net1 $net2 $net3

echo "INFO: Add relations $(date)"
juju-add-relation "nova-compute:shared-db" "mysql:shared-db"
juju-add-relation "keystone:shared-db" "mysql:shared-db"
juju-add-relation "glance:shared-db" "mysql:shared-db"
juju-add-relation "keystone:identity-service" "glance:identity-service"
juju-add-relation "nova-cloud-controller:image-service" "glance:image-service"
juju-add-relation "nova-cloud-controller:identity-service" "keystone:identity-service"
juju-add-relation "nova-cloud-controller:cloud-compute" "nova-compute:cloud-compute"
juju-add-relation "nova-compute:image-service" "glance:image-service"
juju-add-relation "nova-compute:amqp" "rabbitmq-server:amqp"
juju-add-relation "nova-cloud-controller:shared-db" "mysql:shared-db"
juju-add-relation "nova-cloud-controller:amqp" "rabbitmq-server:amqp"
juju-add-relation "openstack-dashboard" "keystone"

juju-add-relation "neutron-api:shared-db" "mysql:shared-db"
juju-add-relation "neutron-api:neutron-api" "nova-cloud-controller:neutron-api"
juju-add-relation "neutron-api:identity-service" "keystone:identity-service"
juju-add-relation "neutron-api:amqp" "rabbitmq-server:amqp"

juju-add-relation "neutron-api" "ntp"
juju-add-relation "nova-compute:juju-info" "ntp:juju-info"
juju-add-relation "neutron-gateway" "ntp"
juju-add-relation "neutron-gateway" "mysql:shared-db"
juju-add-relation "neutron-gateway" "rabbitmq-server:amqp"
juju-add-relation "neutron-gateway" "nova-cloud-controller"
juju-add-relation "neutron-gateway" "neutron-api"

juju add-relation "neutron-openvswitch" "nova-compute"
juju add-relation "neutron-openvswitch" "neutron-api"
juju add-relation "neutron-openvswitch" "rabbitmq-server"

post_deploy

trap - ERR EXIT
