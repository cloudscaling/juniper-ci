#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/../common/functions"
source "$my_dir/functions"

# it also sets variables with names
check_containers

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

prepare_repo
repo_ip=`get-machine-ip-by-number $m0`
repo_key=`curl -s http://$repo_ip/ubuntu/repo.key`
repo_key=`echo "$repo_key" | awk '{printf("      %s\r", $0)}'`

general_type="mem=8G cores=2 root-disk=40G"
compute_type="mem=7G cores=4 root-disk=40G"
contrail_type="mem=15G cores=2 root-disk=40G"

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
  wait_for_machines $m0 $m1 $m2 $m3 $m4 $m5 $m6 $m7 $m8
else
  wait_for_machines $m1 $m2 $m3 $m4 $m5 $m6
fi

juju-status-tabular

# OpenStack base

juju-deploy cs:$SERIES/ntp

juju-deploy cs:$SERIES/rabbitmq-server --to $m1
juju-deploy cs:$SERIES/percona-cluster mysql --to $m1
juju-set mysql "root-password=$PASSWORD" "max-connections=1500"

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
juju-deploy $PLACE/contrail-keystone-auth --to $m6

juju-deploy $PLACE/contrail-controller --to $m6 --resource contrail-controller="$HOME/docker/$image_controller"
juju-expose contrail-controller
juju-deploy $PLACE/contrail-analyticsdb --to $m6 --resource contrail-analyticsdb="$HOME/docker/$image_analyticsdb"
juju-expose contrail-analyticsdb
juju-deploy $PLACE/contrail-analytics --to $m6 --resource contrail-analytics="$HOME/docker/$image_analytics"
juju-expose contrail-analytics

if [ "$DEPLOY_AS_HA_MODE" == 'true' ] ; then
  juju-add-unit contrail-controller --to $m7
  juju-add-unit contrail-controller --to $m8
  juju-add-unit contrail-analytics --to $m7
  juju-add-unit contrail-analytics --to $m8
  juju-add-unit contrail-analyticsdb --to $m7
  juju-add-unit contrail-analyticsdb --to $m8
fi

cp "$my_dir/repo_config.yaml.tmpl" "repo_config_na.yaml"
sed -i -e "s|{{charm_name}}|contrail-openstack-neutron-api|m" "repo_config_na.yaml"
sed -i -e "s|{{repo_ip}}|$repo_ip|m" "repo_config_na.yaml"
sed -i -e "s|{{repo_key}}|$repo_key|m" "repo_config_na.yaml"
sed -i -e "s|{{series}}|$SERIES|m" "repo_config_na.yaml"
sed -i "s/\r/\n/g" "repo_config_na.yaml"
juju-deploy $PLACE/contrail-openstack-neutron-api --config repo_config_na.yaml

cp "$my_dir/repo_config.yaml.tmpl" "repo_config_c.yaml"
sed -i -e "s|{{charm_name}}|contrail-openstack-compute|m" "repo_config_c.yaml"
sed -i -e "s|{{repo_ip}}|$repo_ip|m" "repo_config_c.yaml"
sed -i -e "s|{{repo_key}}|$repo_key|m" "repo_config_c.yaml"
sed -i -e "s|{{series}}|$SERIES|m" "repo_config_c.yaml"
sed -i "s/\r/\n/g" "repo_config_c.yaml"
juju-deploy $PLACE/contrail-openstack-compute --config repo_config_c.yaml

if [ "$DEPLOY_AS_HA_MODE" == 'true' ] ; then
  juju-deploy cs:$SERIES/haproxy --to $m0
  juju-expose haproxy
  juju-add-relation "contrail-analytics" "haproxy"
  juju-add-relation "contrail-controller" "haproxy"
fi

apply_ssl

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

juju-add-relation "contrail-controller" "ntp"
juju-add-relation "nova-compute" "ntp"

juju-add-relation "contrail-controller" "contrail-keystone-auth"
juju-add-relation "contrail-keystone-auth" "keystone"
juju-add-relation "contrail-controller" "contrail-analytics"
juju-add-relation "contrail-controller" "contrail-analyticsdb"
juju-add-relation "contrail-analytics" "contrail-analyticsdb"

juju-add-relation "contrail-openstack-neutron-api" "neutron-api"
juju-add-relation "contrail-openstack-neutron-api" "contrail-controller"

juju-add-relation "nova-compute" "contrail-openstack-compute"
juju-add-relation "contrail-openstack-compute" "contrail-controller"

post_deploy
