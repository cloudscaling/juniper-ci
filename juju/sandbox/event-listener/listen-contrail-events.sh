#!/bin/bash -eux

my_file="$(readlink -e "$0")"
my_dir="$(dirname ${my_file})"

export ANALYTICS_HOST=${ANALYTICS_HOST:-'127.0.0.1'}
export SSH_KEY=${SSH_KEY:-'/opt/sandbox/juju/.local/share/juju/ssh/juju_id_rsa'}
export FIP_ASSOCIATE_SCRIPT=${FIP_ASSOCIATE_SCRIPT:-"${my_dir}/fip-associate.sh"}
export FIP_DISASSOCIATE_SCRIPT=${FIP_DISASSOCIATE_SCRIPT:-"${my_dir}/fip-disassociate.sh"}

url="http://${ANALYTICS_HOST}:8081/analytics/uve-stream?tablefilt=virtual-machine-interface"

while true; do
    os_token=`openstack token issue | awk '/ id / {print $4}'`
    python ${my_dir}/contrail-listener.py \
        --headers "{\"X-Auth-Token\": \"${os_token}\"}" \
        --url ${url} \
        --fip_associate ${FIP_ASSOCIATE_SCRIPT} \
        --fip_disassociate ${FIP_DISASSOCIATE_SCRIPT} || /bin/true

    sleep 1
done