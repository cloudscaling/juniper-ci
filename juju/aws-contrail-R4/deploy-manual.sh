#!/bin/bash -eE

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"
source "$my_dir/../common/functions"
source "$my_dir/functions"

# it also sets variables with names
check_containers

trap 'catch_errors_ce $LINENO' ERR EXIT
function catch_errors_ce() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

jver="$(juju-version)"
if [[ "$jver" == 1 ]] ; then
  exit 1
else
  # version 2
  PLACE="--series=$SERIES $WORKSPACE/contrail-charms"
fi

echo "---------------------------------------------------- Version: $VERSION"

prepare_repo
repo_ip=`get-machine-ip-by-number $mrepo`
repo_key=`curl -s http://$repo_ip/ubuntu/repo.key`
repo_key=`echo "$repo_key" | awk '{printf("      %s\r", $0)}'`

if [[ "$USE_ADDITIONAL_INTERFACE" == "true" ]] ; then
  detect_subnet
fi

general_type="mem=8G cores=2 root-disk=40G"
compute_type="mem=7G cores=4 root-disk=40G"
contrail_type="mem=15G cores=2 root-disk=300G"

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
machines=($m1 $m2 $m3 $m4 $m5 $m6)

wait_for_machines ${machines[@]}
if [[ "$USE_ADDITIONAL_INTERFACE" == "true" ]] ; then
  for mch in ${machines[@]} ; do
    add_interface $mch
  done
fi

cleanup_computes

juju-ssh $m2 "sudo DEBIAN_FRONTEND=noninteractive apt-get install -fy linux-image-4.4.0-1038-aws linux-headers-4.4.0-1038-aws"
juju-ssh $m2 "sudo DEBIAN_FRONTEND=noninteractive apt-get purge -fy linux-image-4.4.0-1092-aws linux-image-\$(uname -r)"
juju-ssh $m2 "sudo reboot"

juju-ssh $m3 "sudo DEBIAN_FRONTEND=noninteractive apt-get install -fy linux-image-4.4.0-1038-aws linux-headers-4.4.0-1038-aws"
juju-ssh $m3 "sudo DEBIAN_FRONTEND=noninteractive apt-get purge -fy linux-image-4.4.0-1092-aws linux-image-\$(uname -r)"
juju-ssh $m3 "sudo reboot"

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
juju-deploy $PLACE/contrail-keystone-auth contrail4-keystone-auth --to $m6

juju-deploy $PLACE/contrail-controller contrail4-controller --to $m6
juju-set contrail4-controller auth-mode=$AAA_MODE "log-level=SYS_DEBUG"
juju-expose contrail4-controller
if [ "$USE_EXTERNAL_RABBITMQ" == 'true' ]; then
  juju-set contrail4-controller "use-external-rabbitmq=true"
fi
juju-deploy $PLACE/contrail-analyticsdb contrail4-analyticsdb --to $m6
juju-set contrail4-analyticsdb "log-level=SYS_DEBUG"
juju-deploy $PLACE/contrail-analytics contrail4-analytics --to $m6
juju-set contrail4-analytics "log-level=SYS_DEBUG"
juju-expose contrail4-analytics

cp "$my_dir/../common/repo_config.yaml.tmpl" "repo_config_co.yaml"
sed -i -e "s|{{charm_name}}|contrail4-openstack|m" "repo_config_co.yaml"
sed -i -e "s|{{repo_ip}}|$repo_ip|m" "repo_config_co.yaml"
sed -i -e "s|{{repo_key}}|$repo_key|m" "repo_config_co.yaml"
sed -i -e "s|{{series}}|$SERIES|m" "repo_config_co.yaml"
sed -i "s/\r/\n/g" "repo_config_co.yaml"
juju-deploy $PLACE/contrail-openstack contrail4-openstack --config repo_config_co.yaml

cp "$my_dir/../common/repo_config.yaml.tmpl" "repo_config_cv.yaml"
sed -i -e "s|{{charm_name}}|contrail4-agent|m" "repo_config_cv.yaml"
sed -i -e "s|{{repo_ip}}|$repo_ip|m" "repo_config_cv.yaml"
sed -i -e "s|{{repo_key}}|$repo_key|m" "repo_config_cv.yaml"
sed -i -e "s|{{series}}|$SERIES|m" "repo_config_cv.yaml"
sed -i "s/\r/\n/g" "repo_config_cv.yaml"
juju-deploy $PLACE/contrail-agent contrail4-agent --config repo_config_cv.yaml
juju-set contrail4-agent "log-level=SYS_DEBUG"

if [[ "$USE_ADDITIONAL_INTERFACE" == "true" ]] ; then
  juju-set contrail4-controller control-network=$subnet_cidr
  juju-set contrail4-analyticsdb control-network=$subnet_cidr
  juju-set contrail4-analytics control-network=$subnet_cidr
fi

echo "INFO: Update endpoints $(date)"
hack_openstack
echo "INFO: Apply SSL flag if set $(date)"
apply_ssl contrail4

echo "INFO: Attach contrail4-controller container $(date)"
juju-attach contrail4-controller contrail-controller="$HOME/docker/$image_controller"
echo "INFO: Attach contrail4-analyticsdb container $(date)"
juju-attach contrail4-analyticsdb contrail-analyticsdb="$HOME/docker/$image_analyticsdb"
echo "INFO: Attach contrail4-analytics container $(date)"
juju-attach contrail4-analytics contrail-analytics="$HOME/docker/$image_analytics"

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

juju-add-relation "contrail4-controller" "ntp"
juju-add-relation "nova-compute:juju-info" "ntp:juju-info"

juju-add-relation "contrail4-controller" "contrail4-keystone-auth"
juju-add-relation "contrail4-keystone-auth" "keystone"
juju-add-relation "contrail4-controller" "contrail4-analytics"
juju-add-relation "contrail4-controller" "contrail4-analyticsdb"
juju-add-relation "contrail4-analytics" "contrail4-analyticsdb"

juju-add-relation "contrail4-openstack" "neutron-api"
juju-add-relation "contrail4-openstack" "nova-compute"
juju-add-relation "contrail4-openstack" "contrail4-controller"

juju-add-relation "contrail4-agent:juju-info" "nova-compute:juju-info"
juju-add-relation "contrail4-agent" "contrail4-controller"

if [ "$USE_EXTERNAL_RABBITMQ" == 'true' ]; then
  juju-add-relation "contrail4-controller" "rabbitmq-server:amqp"
fi

post_deploy

trap - ERR EXIT
