#!/bin/bash -e

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

# version 2
PLACE="--series=$SERIES $WORKSPACE/contrail-charms"

comp1_ip="$addr.$os_comp_1_idx"
comp1=`get_machine_by_ip $comp1_ip`
echo "INFO: compute 1: $comp1 / $comp1_ip"
comp2_ip="$addr.$os_comp_2_idx"
comp2=`get_machine_by_ip $comp2_ip`
echo "INFO: compute 2: $comp2 / $comp2_ip"

cont0_ip="$addr.$os_cont_0_idx"
cont0=`get_machine_by_ip $cont0_ip`
echo "INFO: controller 0 (OpenStack): $cont0 / $cont0_ip"

if [[ "$DEPLOY_MODE" == "one" ]] ; then
  cont1_ip="$cont0_ip"
  cont1="$cont0"
else
  cont1_ip="$addr.$os_cont_1_idx"
  cont1=`get_machine_by_ip $cont1_ip`
fi
echo "INFO: controller 1 (Contrail): $cont1 / $cont1_ip"

if [ "$DEPLOY_MODE" == 'ha' ] ; then
  cont2_ip="$addr.$os_cont_2_idx"
  cont2=`get_machine_by_ip $cont2_ip`
  echo "INFO: controller 2 (Contrail): $cont2 / $cont3_ip"
  cont3_ip="$addr.$os_cont_3_idx"
  cont3=`get_machine_by_ip $cont3_ip`
  echo "INFO: controller 3 (Contrail): $cont3 / $cont3_ip"
fi

( set -o posix ; set ) > $log_dir/env

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
juju-set keystone "admin-password=$PASSWORD" "admin-role=admin" "debug=true" "openstack-origin=$OPENSTACK_ORIGIN" "preferred-api-version=3"
juju-expose keystone

juju-deploy cs:$SERIES/heat --to lxd:$cont0
juju-set heat "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose heat

juju-deploy cs:$SERIES/nova-compute --to $comp1
juju-add-unit nova-compute --to $comp2
juju-set nova-compute "debug=true" "openstack-origin=$OPENSTACK_ORIGIN" "virt-type=kvm" "enable-resize=True" "enable-live-migration=True" "migration-auth-type=ssh"

# Neutron
juju-deploy cs:$SERIES/neutron-api --to lxd:$cont0
juju-set neutron-api "debug=true" "manage-neutron-plugin-legacy-mode=false" "openstack-origin=$OPENSTACK_ORIGIN" "neutron-security-groups=true"
juju-set nova-cloud-controller "network-manager=Neutron"
juju-expose neutron-api

# Contrail
juju-deploy $PLACE/contrail-keystone-auth --to lxd:$cont1

if [ "$DEPLOY_MODE" == 'ha' ] ; then
  juju-deploy cs:~boucherv29/keepalived-19 --config virtual_ip=$addr.254
  juju-deploy cs:$SERIES/haproxy --to $cont1 --config peering_mode=active-active
  juju-add-unit haproxy --to $cont2
  juju-add-unit haproxy --to $cont3
  juju-expose haproxy
  juju-add-relation haproxy:juju-info keepalived:juju-info
  controller_params="--config vip=$addr.254"
fi

juju-deploy $PLACE/contrail-controller --to $cont1 $controller_params
juju-expose contrail-controller
juju-set contrail-controller auth-mode=$AAA_MODE cassandra-minimum-diskgb="4" cassandra-jvm-extra-opts="-Xms1g -Xmx2g" docker-registry=$CONTAINER_REGISTRY image-tag=$CONTRAIL_VERSION docker-user=$DOCKER_USERNAME docker-password=$DOCKER_PASSWORD
juju-deploy $PLACE/contrail-analyticsdb --to $cont1
juju-set contrail-analyticsdb cassandra-minimum-diskgb="4" cassandra-jvm-extra-opts="-Xms1g -Xmx2g" docker-registry=$CONTAINER_REGISTRY image-tag=$CONTRAIL_VERSION docker-user=$DOCKER_USERNAME docker-password=$DOCKER_PASSWORD
juju-deploy $PLACE/contrail-analytics --to $cont1
juju-set contrail-analytics docker-registry=$CONTAINER_REGISTRY image-tag=$CONTRAIL_VERSION docker-user=$DOCKER_USERNAME docker-password=$DOCKER_PASSWORD
juju-expose contrail-analytics

if [ "$DEPLOY_MODE" == 'ha' ] ; then
  juju-add-unit contrail-controller --to $cont2
  juju-add-unit contrail-controller --to $cont3
  juju-add-unit contrail-analytics --to $cont2
  juju-add-unit contrail-analytics --to $cont3
  juju-add-unit contrail-analyticsdb --to $cont2
  juju-add-unit contrail-analyticsdb --to $cont3
  juju-add-relation "contrail-analytics" "haproxy"
  juju-add-relation "contrail-controller:http-services" "haproxy"
  juju-add-relation "contrail-controller:https-services" "haproxy"
fi

juju-deploy $PLACE/contrail-openstack
juju-set contrail-openstack docker-registry=$CONTAINER_REGISTRY image-tag=$CONTRAIL_VERSION docker-user=$DOCKER_USERNAME docker-password=$DOCKER_PASSWORD
juju-deploy $PLACE/contrail-agent
juju-set contrail-agent physical-interface=$IF2 docker-registry=$CONTAINER_REGISTRY image-tag=$CONTRAIL_VERSION docker-user=$DOCKER_USERNAME docker-password=$DOCKER_PASSWORD
if [[ "$USE_DPDK" == "true" ]] ; then
  juju-set contrail-agent dpdk=True dpdk-coremask=1,2 dpdk-main-mempool-size=16384
fi

detect_machines
wait_for_machines $m1 $m2 $m3 $m4 $m5
echo "INFO: Apply SSL flag if set $(date)"
apply_ssl contrail

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

juju-add-relation "contrail-controller" "ntp"
juju-add-relation "nova-compute:juju-info" "ntp:juju-info"

juju-add-relation "contrail-controller" "contrail-keystone-auth"
juju-add-relation "contrail-keystone-auth" "keystone"
juju-add-relation "contrail-controller" "contrail-analytics"
juju-add-relation "contrail-controller" "contrail-analyticsdb"
juju-add-relation "contrail-analytics" "contrail-analyticsdb"

juju-add-relation "contrail-openstack" "neutron-api"
juju-add-relation "contrail-openstack" "nova-compute"
juju-add-relation "contrail-openstack" "heat"
juju-add-relation "contrail-openstack" "contrail-controller"

juju-add-relation "contrail-agent:juju-info" "nova-compute:juju-info"
juju-add-relation "contrail-agent" "contrail-controller"

post_deploy

trap - ERR EXIT
