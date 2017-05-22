#!/bin/bash -eux

my_file="$(readlink -e "$0")"
my_dir="$(dirname ${my_file})"

export CONTRAIL_HOST=${CONTRAIL_HOST:-'127.0.0.1'}
export SSH_KEY=${SSH_KEY:-'/opt/sandbox/juju/.local/share/juju/ssh/juju_id_rsa'}
export FIP_ASSOCIATE_SCRIPT=${FIP_ASSOCIATE_SCRIPT:-"${my_dir}/fip-associate.sh"}
export FIP_DISASSOCIATE_SCRIPT=${FIP_DISASSOCIATE_SCRIPT:-"${my_dir}/fip-disassociate.sh"}

user_id=`openstack user show admin | awk '/ id / {print $4}'`
tenant_id=`openstack project list | awk '/ admin / {print $2}'`

while true; do
    os_token=`openstack token issue | awk '/ id / {print $4}'`
    python ${my_dir}/contrail-polling.py \
        --headers "{\"X-Auth-Token\": \"${os_token}\"}" \
        --address ${CONTRAIL_HOST} \
        --user_id ${user_id} \
        --tenant_id ${tenant_id} \
        --fip_associate ${FIP_ASSOCIATE_SCRIPT} \
        --fip_disassociate ${FIP_DISASSOCIATE_SCRIPT} || /bin/true

    sleep 1
done