#!/bin/bash -eux

my_file="$(readlink -e "$0")"
my_dir="$(dirname ${my_file})"

export SSH_KEY=${SSH_KEY:-'/opt/sandbox/juju/.local/share/juju/ssh/juju_id_rsa'}
export FIP_ASSOCIATE_SCRIPT=${FIP_ASSOCIATE_SCRIPT:-"${my_dir}/fip-associate.sh"}
export FIP_DISASSOCIATE_SCRIPT=${FIP_DISASSOCIATE_SCRIPT:-"${my_dir}/fip-disassociate.sh"}


while true; do
    instances=`openstack server list --all-projects`
    fips=`openstack floating ip list --long --noindent -f table`
    echo ${fips}
    fips_arr=(`echo "${fips}" | awk '/ACTIVE/{print($4","$6)}'`)
    echo ${fips_arr[@]}
    for fip in ${fips_arr[@]} ; do
        floating_ip=`echo ${fip} | cut -d ',' -f 1`
        fixed_ip=`echo ${fip} | cut -d ',' -f 2`
        if [[ "${fixed_ip}" != 'None' ]] ; then
            vm_uuid=`echo "${instances}" | grep "${fixed_ip}" | awk '{print $2}'`
            ${FIP_ASSOCIATE_SCRIPT} ${vm_uuid} ${floating_ip} || /bin/true
        else
            # cleanup rules and vgw for dis-associated fips
            compute_nodes=`openstack compute service list -c Host --service nova-compute -f value`
            for n in $compute_nodes ; do
                SSH_NODE_ADDRESS=n ${FIP_DISASSOCIATE_SCRIPT} ${vm_uuid} ${floating_ip} || /bin/true
            done
        fi
    done

    sleep 2
done