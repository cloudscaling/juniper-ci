#!/bin/bash -ex

my_file="${BASH_SOURCE[0]}"
my_dir="$(dirname $my_file)"
source "$my_dir/../common/functions"
source "$my_dir/../common/functions-openstack"

# 0. for simple setup you can setup MASQUERADING on compute hosts
#juju-ssh $m2 "sudo iptables -t nat -A POSTROUTING -o vhost0 -j MASQUERADE"
#juju-ssh $m3 "sudo iptables -t nat -A POSTROUTING -o vhost0 -j MASQUERADE"
# and provision vgw
#juju-ssh $m2 "sudo docker exec contrail-agent /opt/contrail/utils/provision_vgw_interface.py --oper create --interface vgw --subnets 10.5.0.0/24 --routes 0.0.0.0/0 --vrf default-domain:admin:public:public"
#juju-ssh $m3 "sudo docker exec contrail-agent /opt/contrail/utils/provision_vgw_interface.py --oper create --interface vgw --subnets 10.5.0.0/24 --routes 0.0.0.0/0 --vrf default-domain:admin:public:public"

# linklocal?
# contrail-provision-linklocal --api_server_ip 172.31.32.53 --api_server_port 8082 --linklocal_service_name metadata --linklocal_service_ip 169.254.169.254 --linklocal_service_port 80 --ipfabric_service_ip 127.0.0.1 --ipfabric_service_port 8775 --oper del --admin_user admin --admin_password password
# add metadata secret to vrouter.conf and to nova.conf
# restart vrouter-agent and nova (creating vgw must be the last operation or you need to re-create it after restart service)

if [ -z "$WORKSPACE" ] ; then
  export WORKSPACE="$HOME"
fi

cd $WORKSPACE
create_stackrc
source $WORKSPACE/stackrc
create_virtualenv

run_os_checks
