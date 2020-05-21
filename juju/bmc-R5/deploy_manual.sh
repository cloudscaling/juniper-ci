#!/bin/bash -eE

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$functions"

trap 'catch_errors_ce $LINENO' ERR EXIT
function catch_errors_ce() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

comp1_ip="$addr.$comp_1_idx"
comp1=`get_machine_by_ip $comp1_ip`
echo "INFO: compute 1: $comp1 / $comp1_ip"
comp2_ip="$addr.$comp_2_idx"
comp2=`get_machine_by_ip $comp2_ip`
echo "INFO: compute 2: $comp2 / $comp2_ip"

cont0_ip="$addr.$cont_0_idx"
cont0=`get_machine_by_ip $cont0_ip`
echo "INFO: controller for OpenStack: $cont0 / $cont0_ip"

( set -o posix ; set ) > $log_dir/env

# OpenStack base

echo "INFO: Deploy all $(date)"
juju-deploy cs:$SERIES/ubuntu --to $cont0
juju-add-unit ubuntu --to $comp1
juju-add-unit ubuntu --to $comp2
juju-deploy cs:$SERIES/ntp

juju-deploy cs:$SERIES/rabbitmq-server --to lxd:$cont0
juju-deploy cs:$SERIES/percona-cluster mysql --to lxd:$cont0
juju-set mysql "root-password=$PASSWORD" "max-connections=1500"

juju-deploy cs:$SERIES/openstack-dashboard --to lxd:$cont0
juju-set openstack-dashboard "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose openstack-dashboard

juju-deploy cs:$SERIES/nova-cloud-controller --to lxd:$cont0 --config region=$REGION
juju-set nova-cloud-controller "console-access-protocol=novnc" "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose nova-cloud-controller

juju-deploy cs:$SERIES/glance --to lxd:$cont0 --config region=$REGION
juju-set glance "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose glance

juju-deploy cs:$SERIES/keystone --to lxd:$cont0 --config region=$REGION
# by default preferred-api-version=3 for queens and above and =2 for previous versions
juju-set keystone "admin-password=$PASSWORD" "admin-role=admin" "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose keystone

juju-deploy cs:$SERIES/heat --to lxd:$cont0 --config region=$REGION
juju-set heat "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose heat

juju-deploy --series=$SERIES cs:${SERIES}/nova-compute --to $comp1
juju-add-unit nova-compute --to $comp2
juju-set nova-compute "debug=true" "openstack-origin=$OPENSTACK_ORIGIN" "virt-type=kvm" "enable-resize=True" "enable-live-migration=True" "migration-auth-type=ssh"

# Neutron
juju-deploy cs:$SERIES/neutron-api --to lxd:$cont0 --config region=$REGION
juju-set neutron-api "debug=true" "openstack-origin=$OPENSTACK_ORIGIN" "neutron-security-groups=true" "flat-network-providers=physnet1"
juju-set nova-cloud-controller "network-manager=Neutron"
juju-expose neutron-api

juju-deploy cs:$SERIES/neutron-openvswitch

#juju-deploy cs:$SERIES/neutron-gateway --to lxd:$cont0 --config "bridge-mappings=physnet1:br-ex" --config "data-port=br-ex:ens3"
#juju-set neutron-gateway "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"

if [[ "$VERSION" == 'train' ]]; then
  juju-deploy cs:$SERIES/placement --to lxd:$cont0 --config region=$REGION --config "debug=true" --config "openstack-origin=$OPENSTACK_ORIGIN"
  juju-add-relation placement mysql
  juju-add-relation placement keystone
  juju-add-relation placement nova-cloud-controller
fi

# re-write resolv.conf for bionic lxd containers to allow names resolving inside lxd containers
if [[ "$SERIES" == 'bionic' ]]; then
  for mmch in `juju machines | awk '/lxd/{print $1}'` ; do
    echo "INFO: apply DNS config for $mmch"
    res=1
    for i in 0 1 2 3 4 5 ; do
      if juju-ssh $mmch "echo 'nameserver $addr.1' | sudo tee /usr/lib/systemd/resolv.conf ; sudo ln -sf /usr/lib/systemd/resolv.conf /etc/resolv.conf" ; then
        res=0
        break
      fi
      sleep 10
    done
    test $res -eq 0 || { echo "ERROR: Machine $mmch is not accessible"; exit 1; }
  done
fi

echo "INFO: Add relations $(date)"
juju-add-relation "ntp" "ubuntu"
juju-add-relation "keystone:shared-db" "mysql:shared-db"
juju-add-relation "glance:shared-db" "mysql:shared-db"
juju-add-relation "keystone:identity-service" "glance:identity-service"
juju-add-relation "heat:shared-db" "mysql:shared-db"
juju-add-relation "heat:amqp" "rabbitmq-server:amqp"
juju-add-relation "heat" "keystone"
juju-add-relation "nova-cloud-controller:image-service" "glance:image-service"
juju-add-relation "nova-cloud-controller:identity-service" "keystone:identity-service"
juju-add-relation "nova-cloud-controller:cloud-compute" "nova-compute:cloud-compute"
juju-add-relation "nova-compute:image-service" "glance:image-service"
juju-add-relation "nova-compute:amqp" "rabbitmq-server:amqp"
juju-add-relation "nova-cloud-controller:shared-db" "mysql:shared-db"
juju-add-relation "nova-cloud-controller:amqp" "rabbitmq-server:amqp"
juju-add-relation "openstack-dashboard:identity-service" "keystone"

juju-add-relation "neutron-api:shared-db" "mysql:shared-db"
juju-add-relation "neutron-api:neutron-api" "nova-cloud-controller:neutron-api"
juju-add-relation "neutron-api:identity-service" "keystone:identity-service"
juju-add-relation "neutron-api:amqp" "rabbitmq-server:amqp"
juju-add-relation "neutron-openvswitch:neutron-plugin-api" "neutron-api:neutron-plugin-api"
juju-add-relation "nova-compute:neutron-plugin" "neutron-openvswitch:neutron-plugin"
juju-add-relation "neutron-openvswitch:amqp" "rabbitmq-server:amqp"
#juju-add-relation "neutron-gateway:amqp" "rabbitmq-server:amqp"
#juju-add-relation "neutron-gateway:quantum-network-service" "nova-cloud-controller:quantum-network-service"
#juju-add-relation "neutron-gateway:neutron-plugin-api" "neutron-api:neutron-plugin-api"

post_deploy

trap - ERR EXIT
