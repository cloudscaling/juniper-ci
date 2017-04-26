#!/bin/bash -e

if [ ! -d $HOME/docker ] ; then
  echo "ERROR: Please provide container images for deployment in $HOME/docker/"
  exit 1
fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/../common/functions"

jver="$(juju-version)"
deploy_from=${1:-github}   # Place where to get charms - github or charmstore
if [[ "$deploy_from" == github ]] ; then
  if [[ "$jver" == 1 ]] ; then
    exit 1
  else
    # version 2
    PLACE="--series=$SERIES $WORKSPACE/contrail-charms"
  fi
else
  # deploy_from=charmstore
  echo "ERROR: Deploy from charmstore is not supported yet"
  exit 1
fi

echo "---------------------------------------------------- From: $deploy_from  Version: $VERSION"

m1=$(create_machine 2)
echo "INFO: Machine created: $m1"
m2=$(create_machine 1)
echo "INFO: Machine created: $m2"
m3=$(create_machine 1)
echo "INFO: Machine created: $m3"
m4=$(create_machine 0)
echo "INFO: Machine created: $m4"
m5=$(create_machine 0)
echo "INFO: Machine created: $m5"
m6=$(create_machine 2)
echo "INFO: Machine created: $m6"
wait_for_machines $m1 $m2 $m3 $m4 $m5 $m6


function add_packages() {
  mch=$1
  juju-scp "$HOME/docker/contrail-install-packages_4.0.0.0-3046~mitaka_all.deb" "$mch:contrail-install-packages_4.0.0.0-3046~mitaka_all.deb"
  juju-ssh $mch "sudo dpkg -i contrail-install-packages_4.0.0.0-3046~mitaka_all.deb"
  juju-ssh $mch "sudo /opt/contrail/contrail_packages/setup.sh"
}
# add packages only to machine with neutron-api and nova-compute if needed
add_packages $m5
if [[ $VROUTER_AS_CONTAINER == '0' ]] ; then
  add_packages $m2
  add_packages $m3
fi

juju-status-tabular

# OpenStack base

juju-deploy cs:$SERIES/ubuntu --to $m1
juju-add-unit ubuntu --to $m2
juju-add-unit ubuntu --to $m3
juju-add-unit ubuntu --to $m4
juju-add-unit ubuntu --to $m5
juju-add-unit ubuntu --to $m6
juju-deploy cs:$SERIES/ntp

juju-deploy cs:$SERIES/rabbitmq-server --to $m1
juju-deploy cs:$SERIES/percona-cluster mysql --to $m1
juju-set mysql "root-password=password" "max-connections=1500"

juju-deploy cs:$SERIES/openstack-dashboard --to $m1
juju-set openstack-dashboard "debug=true" "openstack-origin=$VERSION"
juju-expose openstack-dashboard

juju-deploy cs:$SERIES/nova-cloud-controller --to $m4
juju-set nova-cloud-controller "console-access-protocol=novnc" "debug=true" "openstack-origin=$VERSION"
juju-expose nova-cloud-controller

juju-deploy cs:$SERIES/glance --to $m2
juju-set glance "debug=true" "openstack-origin=$VERSION"
juju-expose glance

juju-deploy cs:$SERIES/keystone --to $m3
juju-set keystone "admin-password=password" "debug=true" "openstack-origin=$VERSION"
juju-expose keystone

juju-deploy cs:$SERIES/nova-compute --to $m2
juju-add-unit nova-compute --to $m3
juju-set nova-compute "debug=true" "openstack-origin=$VERSION" "virt-type=qemu" "enable-resize=True" "enable-live-migration=True" "migration-auth-type=ssh"

# Neutron

juju-deploy cs:$SERIES/neutron-api --to $m5
juju-set neutron-api "debug=true" "manage-neutron-plugin-legacy-mode=false" "openstack-origin=$VERSION" "neutron-security-groups=true"
juju-set nova-cloud-controller "network-manager=Neutron" "neutron-external-network=pub_net"
juju-expose neutron-api

# Contrail
juju-deploy $PLACE/contrail-controller --to $m6 --resource contrail-controller="$HOME/docker/contrail-controller-u14.04-4.0.0.0-3046.tar.gz"
juju-expose contrail-controller

juju-deploy $PLACE/contrail-analyticsdb --to $m6 --resource contrail-analyticsdb="$HOME/docker/contrail-analyticsdb-u14.04-4.0.0.0-3046.tar.gz"

juju-deploy $PLACE/contrail-analytics --to $m6 --resource contrail-analytics="$HOME/docker/contrail-analytics-u14.04-4.0.0.0-3046.tar.gz"

if [[ $VROUTER_AS_CONTAINER != '0' ]] ; then
  juju-deploy $PLACE/contrail-agent --to $m2 --resource contrail-agent="$HOME/docker/contrail-agent-u14.04-4.0.0.0-3046.tar.gz"
  juju-add-unit contrail-agent --to $m3
fi

juju-deploy $PLACE/contrail-openstack-neutron-api
juju-set contrail-openstack-neutron-api "install-sources="

if [[ $VROUTER_AS_CONTAINER == '0' ]] ; then
  juju-deploy $PLACE/contrail-openstack-compute
  juju-set contrail-openstack-compute "install-sources=" "vhost-interface=eth0"
fi

sleep 30

juju-add-relation "ubuntu" "ntp"

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

juju-add-relation "contrail-openstack-neutron-api" "neutron-api"
juju-add-relation "contrail-openstack-neutron-api" "keystone"

juju-add-relation "contrail-controller" "keystone"

if [[ $VROUTER_AS_CONTAINER != '0' ]] ; then
  juju-add-relation "contrail-agent" "keystone"
  juju-add-relation "contrail-agent" "contrail-controller"
fi

juju-add-relation "contrail-openstack-neutron-api" "contrail-controller"

juju-add-relation "contrail-controller" "contrail-analytics"
juju-add-relation "contrail-controller" "contrail-analyticsdb"
juju-add-relation "contrail-analytics" "contrail-analyticsdb"

if [[ $VROUTER_AS_CONTAINER == '0' ]] ; then
  juju-add-relation "nova-compute" "contrail-openstack-compute"
  juju-add-relation "contrail-openstack-compute" "keystone"
  juju-add-relation "contrail-openstack-compute" "contrail-controller"
fi

sleep 30
echo "INFO: Wait for services start: $(date)"
wait_absence_status_for_services "executing|blocked|waiting"
echo "INFO: Wait for services end: $(date)"

if [[ "$jver" == 2 ]] ; then
  # Juju 2.0 registers services with private ips (using new modern tool 'network-get public')
  echo "INFO: HACK: Reconfigure public endpoints for OpenStack $(date)"
  ip=`get-machine-ip-by-number $m4`
  juju-set nova-cloud-controller os-public-hostname=$ip
  ip=`get-machine-ip-by-number $m5`
  juju-set neutron-api os-public-hostname=$ip
  ip=`get-machine-ip-by-number $m2`
  juju-set glance os-public-hostname=$ip
  ip=`get-machine-ip-by-number $m3`
  juju-set keystone os-public-hostname=$ip
  echo "INFO: Wait for services start: $(date)"
  wait_absence_status_for_services "executing|blocked|waiting|allocating" 10
  echo "INFO: Wait for services end: $(date)"
fi

# open port for vnc console
open_port $m4 6080

juju-status-tabular

if [[ $VROUTER_AS_CONTAINER != '0' ]] ; then
  # 1. change hypervisor type to kvm
  juju-ssh $m2 "sudo docker exec -it contrail-agent sed -i 's/^# type=.*/type=kvm/g' /etc/contrail/contrail-vrouter-agent.conf"
  juju-ssh $m2 "sudo docker exec -it contrail-agent service contrail-vrouter-agent restart"
  juju-ssh $m3 "sudo docker exec -it contrail-agent sed -i 's/^# type=.*/type=kvm/g' /etc/contrail/contrail-vrouter-agent.conf"
  juju-ssh $m3 "sudo docker exec -it contrail-agent service contrail-vrouter-agent restart"
fi
