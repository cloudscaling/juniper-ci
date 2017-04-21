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
# add packages only to machine with neutron-api
add_packages $m5

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
juju-deploy $PLACE/contrail-controller --to $m6 --resource contrail-controller="./docker/contrail-controller-u14.04-4.0.0.0-3046.tar.gz"
juju-expose contrail-controller

juju-deploy $PLACE/contrail-analyticsdb --to $m6 --resource contrail-analyticsdb="./docker/contrail-analyticsdb-u14.04-4.0.0.0-3046.tar.gz"

juju-deploy $PLACE/contrail-analytics --to $m6 --resource contrail-analytics="./docker/contrail-analytics-u14.04-4.0.0.0-3046.tar.gz"

juju-deploy $PLACE/contrail-agent --to $m2 --resource contrail-agent="./docker/contrail-agent-u14.04-4.0.0.0-3046.tar.gz"
juju-add-unit contrail-agent --to $m3

juju-deploy $PLACE/neutron-api-contrail
juju-set neutron-api-contrail "install-sources="

#juju-deploy $PLACE/neutron-contrail
#juju-set neutron-contrail "install-sources=" "vhost-interface=eth0" "virtual-gateways=[ { project: admin, network: public, interface: vgw, subnets: [ 10.5.0.0/24 ], routes: [ 0.0.0.0/0 ] } ]"

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

juju-add-relation "neutron-api-contrail" "neutron-api"
juju-add-relation "neutron-api-contrail" "keystone"

juju-add-relation "contrail-controller" "keystone"
juju-add-relation "contrail-analytics" "keystone"
juju-add-relation "contrail-analyticsdb" "keystone"
juju-add-relation "contrail-agent" "keystone"

juju-add-relation "contrail-agent" "contrail-controller"
juju-add-relation "neutron-api-contrail" "contrail-controller"

juju-add-relation "contrail-controller:contrail-controller" "contrail-analytics:contrail-controller"
juju-add-relation "contrail-controller:contrail-analytics" "contrail-analytics:contrail-analytics"
juju-add-relation "contrail-controller" "contrail-analyticsdb:contrail-controller"
juju-add-relation "contrail-analytics" "contrail-analyticsdb:contrail-analytics"
juju-add-relation "contrail-analytics" "contrail-analyticsdb:contrail-analyticsdb"


#juju-add-relation "nova-compute" "neutron-contrail"
#juju-add-relation "neutron-contrail" "keystone"
#juju-add-relation "neutron-contrail:contrail-controller" "contrail-controller:contrail-controller"
#juju-add-relation "neutron-contrail" "contrail-analytics"

sleep 30

juju-status-tabular

echo "INFO: Wait for services start: $(date)"
wait_absence_status_for_services "executing|blocked|waiting"
echo "INFO: Wait for services end: $(date)"

juju-status-tabular

# 1. change hypervisor type to kvm
juju-ssh $m2 "sudo docker exec -it contrail-agent sed -i 's/^# type=.*/type=kvm/g' /etc/contrail/contrail-vrouter-agent.conf"
juju-ssh $m2 "sudo docker exec -it contrail-agent service contrail-vrouter-agent restart"
juju-ssh $m3 "sudo docker exec -it contrail-agent sed -i 's/^# type=.*/type=kvm/g' /etc/contrail/contrail-vrouter-agent.conf"
juju-ssh $m3 "sudo docker exec -it contrail-agent service contrail-vrouter-agent restart"

# 0. for simple setup you can setup MASQUERADING on compute hosts
#juju-ssh $m2 "sudo iptables -t nat -A POSTROUTING -o vhost0 -j MASQUERADE"
#juju-ssh $m3 "sudo iptables -t nat -A POSTROUTING -o vhost0 -j MASQUERADE"
# and provision vgw
juju-ssh $m2 "sudo docker exec contrail-agent /opt/contrail/utils/provision_vgw_interface.py --oper create --interface vgw --subnets 10.5.0.0/24 --routes 0.0.0.0/0 --vrf default-domain:admin:public:public"
juju-ssh $m3 "sudo docker exec contrail-agent /opt/contrail/utils/provision_vgw_interface.py --oper create --interface vgw --subnets 10.5.0.0/24 --routes 0.0.0.0/0 --vrf default-domain:admin:public:public"

# linklocal?
# contrail-provision-linklocal --api_server_ip 172.31.32.53 --api_server_port 8082 --linklocal_service_name metadata --linklocal_service_ip 169.254.169.254 --linklocal_service_port 80 --ipfabric_service_ip 127.0.0.1 --ipfabric_service_port 8775 --oper del --admin_user admin --admin_password password
# add metadata secret to vrouter.conf and to nova.conf
# restart vrouter-agent and nova (creating vgw must be the last operation or you need to re-create it after restart service)
