#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/functions"
source "$my_dir/../common/functions"
source "$my_dir/../contrail/functions"

# it also sets variables with names
check_containers

# version 2
PLACE="--series=$SERIES $WORKSPACE/contrail-charms"

echo "---------------------------------------------------- From: $deploy_from  Version: $VERSION"

repo_ip=`get_machine_ip $juju_cont_mac`
mrepo="ubuntu@$repo_ip"
echo "INFO: Prepare apt-repo on $mrepo"
scp "$HOME/docker/$packages" "$mrepo:contrail_debs.tgz"
scp "$my_dir/create-aptrepo.sh" $mrepo:create-aptrepo.sh
ssh $mrepo ./create-aptrepo.sh $SERIES
echo "INFO: apt-repo is ready"
repo_key=`curl -s http://$repo_ip/ubuntu/repo.key`
repo_key=`echo "$repo_key" | awk '{printf("      %s\r", $0)}'`

#if [[ "$USE_ADDITIONAL_INTERFACE" == "true" ]] ; then
#  detect_subnet
#fi

comp1_ip=`get_machine_ip $juju_os_comp_1_mac`
comp1=`juju status | grep $comp1_ip | awk '{print $1}'`
echo "INFO: compute 1: $comp1 / $comp1_ip"
comp2_ip=`get_machine_ip $juju_os_comp_2_mac`
comp2=`juju status | grep $comp2_ip | awk '{print $1}'`
echo "INFO: compute 2: $comp2 / $comp2_ip"
cont1_ip=`get_machine_ip $juju_os_cont_1_mac`
cont1=`juju status | grep $cont1_ip | awk '{print $1}'`
echo "INFO: controller 1: $cont1 / $cont1_ip"
if [ "$DEPLOY_AS_HA_MODE" == 'true' ] ; then
  cont2_ip=`get_machine_ip $juju_os_cont_2_mac`
  cont2=`juju status | grep $cont2_ip | awk '{print $1}'`
  echo "INFO: controller 2: $cont2 / $cont3_ip"
  cont3_ip=`get_machine_ip $juju_os_cont_3_mac`
  cont3=`juju status | grep $cont3_ip | awk '{print $1}'`
  echo "INFO: controller 3: $cont3 / $cont3_ip"
fi

#if [[ "$USE_ADDITIONAL_INTERFACE" == "true" ]] ; then
#  for mch in ${machines[@]} ; do
#    add_interface $mch
#  done
#fi

# OpenStack base

echo "INFO: Deploy all $(date)"
juju-deploy cs:$SERIES/ntp

juju-deploy cs:$SERIES/rabbitmq-server --to lxd:$cont1
juju-deploy cs:$SERIES/percona-cluster mysql --to lxd:$cont1
juju-set mysql "root-password=$PASSWORD" "max-connections=1500"

juju-deploy cs:$SERIES/openstack-dashboard --to lxd:$cont1
juju-set openstack-dashboard "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose openstack-dashboard

juju-deploy cs:$SERIES/nova-cloud-controller --to lxd:$cont1
juju-set nova-cloud-controller "console-access-protocol=novnc" "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose nova-cloud-controller

juju-deploy cs:$SERIES/glance --to lxd:$cont1
juju-set glance "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose glance

juju-deploy cs:$SERIES/keystone --to lxd:$cont1
juju-set keystone "admin-password=$PASSWORD" "admin-role=admin" "debug=true" "openstack-origin=$OPENSTACK_ORIGIN"
juju-expose keystone

juju-deploy cs:$SERIES/nova-compute --to $comp1
juju-add-unit nova-compute --to $comp2
juju-set nova-compute "debug=true" "openstack-origin=$OPENSTACK_ORIGIN" "virt-type=qemu" "enable-resize=True" "enable-live-migration=True" "migration-auth-type=ssh"

# Neutron
juju-deploy cs:$SERIES/neutron-api --to lxd:$cont1
juju-set neutron-api "debug=true" "manage-neutron-plugin-legacy-mode=false" "openstack-origin=$OPENSTACK_ORIGIN" "neutron-security-groups=true"
juju-set nova-cloud-controller "network-manager=Neutron"
juju-expose neutron-api

# Contrail
juju-deploy $PLACE/contrail-keystone-auth --to lxd:$cont1

juju-deploy $PLACE/contrail-controller --to $cont1
juju-expose contrail-controller
juju-deploy $PLACE/contrail-analyticsdb --to $cont1
juju-deploy $PLACE/contrail-analytics --to $cont1
juju-expose contrail-analytics

#if [ "$DEPLOY_AS_HA_MODE" == 'true' ] ; then
#  juju-add-unit contrail-controller --to $m7
#  juju-add-unit contrail-controller --to $m8
#  juju-add-unit contrail-analytics --to $m7
#  juju-add-unit contrail-analytics --to $m8
#  juju-add-unit contrail-analyticsdb --to $m7
#  juju-add-unit contrail-analyticsdb --to $m8
#fi

cp "$my_dir/repo_config.yaml.tmpl" "repo_config_co.yaml"
sed -i -e "s|{{charm_name}}|contrail-openstack|m" "repo_config_co.yaml"
sed -i -e "s|{{repo_ip}}|$repo_ip|m" "repo_config_co.yaml"
sed -i -e "s|{{repo_key}}|$repo_key|m" "repo_config_co.yaml"
sed -i -e "s|{{series}}|$SERIES|m" "repo_config_co.yaml"
sed -i "s/\r/\n/g" "repo_config_co.yaml"
juju-deploy $PLACE/contrail-openstack --config repo_config_co.yaml

cp "$my_dir/repo_config.yaml.tmpl" "repo_config_cv.yaml"
sed -i -e "s|{{charm_name}}|contrail-agent|m" "repo_config_cv.yaml"
sed -i -e "s|{{repo_ip}}|$repo_ip|m" "repo_config_cv.yaml"
sed -i -e "s|{{repo_key}}|$repo_key|m" "repo_config_cv.yaml"
sed -i -e "s|{{series}}|$SERIES|m" "repo_config_cv.yaml"
sed -i "s/\r/\n/g" "repo_config_cv.yaml"
juju-deploy $PLACE/contrail-agent --config repo_config_cv.yaml

#if [[ "$USE_ADDITIONAL_INTERFACE" == "true" ]] ; then
#  juju-set contrail-controller control-network=$subnet_cidr
#  juju-set contrail-analyticsdb control-network=$subnet_cidr
#  juju-set contrail-analytics control-network=$subnet_cidr
#  juju-set contrail-agent control-network=$subnet_cidr
#fi

#if [ "$DEPLOY_AS_HA_MODE" == 'true' ] ; then
#  juju-deploy cs:$SERIES/haproxy --to $m0
#  juju-expose haproxy
#  juju-add-relation "contrail-analytics" "haproxy"
#  juju-add-relation "contrail-controller:http-services" "haproxy"
#  juju-add-relation "contrail-controller:https-services" "haproxy"
#  ip=`get-machine-ip-by-number $m0`
#  juju-set contrail-controller vip=$ip
#fi

#echo "INFO: Update endpoints $(date)"
#hack_openstack
#echo "INFO: Apply SSL flag if set $(date)"
#apply_ssl

echo "INFO: Attach contrail-controller container $(date)"
juju-attach contrail-controller contrail-controller="$HOME/docker/$image_controller"
echo "INFO: Attach contrail-analyticsdb container $(date)"
juju-attach contrail-analyticsdb contrail-analyticsdb="$HOME/docker/$image_analyticsdb"
echo "INFO: Attach contrail-analytics container $(date)"
juju-attach contrail-analytics contrail-analytics="$HOME/docker/$image_analytics"

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

juju-add-relation "contrail-controller" "ntp"
juju-add-relation "nova-compute:juju-info" "ntp:juju-info"

juju-add-relation "contrail-controller" "contrail-keystone-auth"
juju-add-relation "contrail-keystone-auth" "keystone"
juju-add-relation "contrail-controller" "contrail-analytics"
juju-add-relation "contrail-controller" "contrail-analyticsdb"
juju-add-relation "contrail-analytics" "contrail-analyticsdb"

juju-add-relation "contrail-openstack" "neutron-api"
juju-add-relation "contrail-openstack" "nova-compute"
juju-add-relation "contrail-openstack" "contrail-controller"

juju-add-relation "contrail-agent:juju-info" "nova-compute:juju-info"
juju-add-relation "contrail-agent" "contrail-controller"

post_deploy
