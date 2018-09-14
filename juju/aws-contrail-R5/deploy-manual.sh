#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/../common/functions"
source "$my_dir/functions"

trap 'catch_errors_ce $LINENO' ERR EXIT
function catch_errors_ce() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

# version 2
PLACE="--series=$SERIES $WORKSPACE/contrail-charms"

echo "---------------------------------------------------- Version: $VERSION"

if [[ "$USE_ADDITIONAL_INTERFACE" == "true" ]] ; then
  detect_subnet
fi

general_type="mem=8G cores=2 root-disk=40G"
compute_type="mem=7G cores=4 root-disk=40G"
contrail_type="mem=15G cores=2 root-disk=300G"

if [ "$DEPLOY_AS_HA_MODE" == 'true' ] ; then
  m0=$(create_machine $general_type)
  echo "INFO: General machine created: $m0"
fi
m1=$(create_machine $general_type)
echo "INFO: General machine created: $m1"
m2=$(create_machine $compute_type)
echo "INFO: Compute machine created: $m2"
m3=$(create_machine $compute_type)
echo "INFO: Compute machine created: $m3"
m4=$(create_machine $general_type)
echo "INFO: General machine created: $m4"
m5=$(create_machine $general_type)
echo "INFO: General machine created: $m5"
m6=$(create_machine $contrail_type)
echo "INFO: Contrail machine created: $m6"
if [ "$DEPLOY_AS_HA_MODE" == 'true' ] ; then
  m7=$(create_machine $contrail_type)
  echo "INFO: Contrail machine created: $m7"
  m8=$(create_machine $contrail_type)
  echo "INFO: Contrail machine created: $m8"
  machines=($m0 $m1 $m2 $m3 $m4 $m5 $m6 $m7 $m8)
else
  machines=($m1 $m2 $m3 $m4 $m5 $m6)
fi

wait_for_machines ${machines[@]}
if [[ "$USE_ADDITIONAL_INTERFACE" == "true" ]] ; then
  for mch in ${machines[@]} ; do
    add_interface $mch
  done
fi

cleanup_computes

juju-status-tabular

# OpenStack base

echo "INFO: Deploy all $(date)"
juju-deploy cs:$SERIES/ntp

juju-deploy cs:$SERIES/rabbitmq-server --to $m1
juju-deploy cs:$SERIES/percona-cluster mysql --config "root-password=$PASSWORD" --config "max-connections=1500" --to $m1

juju-deploy cs:$SERIES/openstack-dashboard --to $m1
juju-set openstack-dashboard "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose openstack-dashboard

juju-deploy cs:$SERIES/nova-cloud-controller --to $m4
juju-set nova-cloud-controller "console-access-protocol=novnc" "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose nova-cloud-controller

juju-deploy cs:$SERIES/glance --to $m2
juju-set glance "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose glance

juju-deploy cs:$SERIES/keystone --to $m3
juju-set keystone "admin-password=$PASSWORD" "admin-role=admin" "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose keystone

juju-deploy cs:$SERIES/nova-compute --to $m2
juju-add-unit nova-compute --to $m3
juju-set nova-compute "debug=true" "openstack-origin=$OPENSTACK_ORIGIN" "virt-type=qemu" "enable-resize=True" "enable-live-migration=True" "migration-auth-type=ssh"

# Neutron
juju-deploy cs:$SERIES/neutron-api --to $m5
juju-set neutron-api "debug=true" "manage-neutron-plugin-legacy-mode=false" "openstack-origin=$OPENSTACK_ORIGIN" "neutron-security-groups=true"
juju-set nova-cloud-controller "network-manager=Neutron"
juju-expose neutron-api

# Contrail
juju-deploy $PLACE/contrail-keystone-auth contrail5-keystone-auth --to $m6

juju-deploy $PLACE/contrail-controller contrail5-controller --to $m6
juju-set contrail5-controller auth-mode=$AAA_MODE "log-level=SYS_DEBUG" cassandra-minimum-diskgb="4" cassandra-jvm-extra-opts="-Xms1g -Xmx2g"
juju-deploy $PLACE/contrail-analyticsdb contrail5-analyticsdb --to $m6
juju-set contrail5-analyticsdb "log-level=SYS_DEBUG" cassandra-minimum-diskgb="4" cassandra-jvm-extra-opts="-Xms1g -Xmx2g"
juju-deploy $PLACE/contrail-analytics contrail5-analytics --to $m6
juju-set contrail5-analytics "log-level=SYS_DEBUG"

if [ "$DEPLOY_AS_HA_MODE" == 'true' ] ; then
  juju-add-unit contrail5-controller --to $m7
  juju-add-unit contrail5-controller --to $m8
  juju-add-unit contrail5-analytics --to $m7
  juju-add-unit contrail5-analytics --to $m8
  juju-add-unit contrail5-analyticsdb --to $m7
  juju-add-unit contrail5-analyticsdb --to $m8
fi

juju-deploy $PLACE/contrail-openstack contrail5-openstack
juju-deploy $PLACE/contrail-agent contrail5-agent
juju-set contrail5-agent "log-level=SYS_DEBUG"

if [[ "$USE_ADDITIONAL_INTERFACE" == "true" ]] ; then
  juju-set contrail5-controller control-network=$subnet_cidr
  juju-set contrail5-analyticsdb control-network=$subnet_cidr
  juju-set contrail5-analytics control-network=$subnet_cidr
fi

if [ "$DEPLOY_AS_HA_MODE" == 'true' ] ; then
  juju-deploy cs:~boucherv29/keepalived-19
  juju-deploy cs:$SERIES/haproxy --to $m6 --config peering_mode=active-active
  juju-add-unit haproxy --to $m7
  juju-add-unit haproxy --to $m8
  juju-expose haproxy
  juju-add-relation haproxy:juju-info keepalived:juju-info
  juju-add-relation "contrail5-analytics" "haproxy"
  juju-add-relation "contrail5-controller:http-services" "haproxy"
  juju-add-relation "contrail5-controller:https-services" "haproxy"

  subnet_id=`aws ec2 describe-subnets --filters Name=availability-zone,Values=$AZ Name=vpc-id,Values=$vpc_id Name=defaultForAz,Values=True --query 'Subnets[*].SubnetId' --output text`
  subnet_cidr=`aws ec2 describe-subnets --subnet-id $subnet_id --query 'Subnets[0].CidrBlock' --output text`
  vip=`python -c "import netaddr; print(netaddr.IPNetwork(u'$subnet_cidr').broadcast - 1)"`
  juju-set contrail5-controller vip=$vip
  juju-set keepalived virtual_ip=$vip
else
  juju-expose contrail5-controller
  juju-expose contrail5-analytics
fi

echo "INFO: Update endpoints $(date)"
hack_openstack
echo "INFO: Apply SSL flag if set $(date)"
apply_ssl contrail5

echo "INFO: Add relations $(date)"
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
juju-add-relation "openstack-dashboard:identity-service" "keystone"

juju-add-relation "neutron-api:shared-db" "mysql:shared-db"
juju-add-relation "neutron-api:neutron-api" "nova-cloud-controller:neutron-api"
juju-add-relation "neutron-api:identity-service" "keystone:identity-service"
juju-add-relation "neutron-api:amqp" "rabbitmq-server:amqp"

juju-add-relation "contrail5-controller" "ntp"
juju-add-relation "nova-compute:juju-info" "ntp:juju-info"

juju-add-relation "contrail5-controller" "contrail5-keystone-auth"
juju-add-relation "contrail5-keystone-auth" "keystone"
juju-add-relation "contrail5-controller" "contrail5-analytics"
juju-add-relation "contrail5-controller" "contrail5-analyticsdb"
juju-add-relation "contrail5-analytics" "contrail5-analyticsdb"

juju-add-relation "contrail5-openstack" "neutron-api"
juju-add-relation "contrail5-openstack" "nova-compute"
juju-add-relation "contrail5-openstack" "contrail5-controller"

juju-add-relation "contrail5-agent:juju-info" "nova-compute:juju-info"
juju-add-relation "contrail5-agent" "contrail5-controller"

post_deploy

trap - ERR EXIT
