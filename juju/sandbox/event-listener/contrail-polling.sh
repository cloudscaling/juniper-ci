#!/bin/bash -eux

my_file="$(readlink -e "$0")"
my_dir="$(dirname ${my_file})"

export SSH_KEY=${SSH_KEY:-'/opt/sandbox/juju/.local/share/juju/ssh/juju_id_rsa'}
export FIP_ASSOCIATE_SCRIPT=${FIP_ASSOCIATE_SCRIPT:-"${my_dir}/fip-associate.sh"}
export FIP_DISASSOCIATE_SCRIPT=${FIP_DISASSOCIATE_SCRIPT:-"${my_dir}/fip-disassociate.sh"}


while true; do
    compute_nodes=`openstack compute service list -c Host --service nova-compute -f value`
    instances=`openstack server list --all-projects`
    fips=`openstack floating ip list --long --noindent -f table`
    fips_arr=('')
    if [[ -n "${fips}" ]] ; then
        fips_arr=(`echo "${fips}" | awk '/ACTIVE/{print($4","$6)}'`)
    fi
    # add elastic IP for cleanup that are deleted from OS (they are not returned by openstack floating ip list)
    elastic_ips=`aws ec2 describe-addresses --query 'Addresses[*].PublicIp' --output text`
    for eip in ${elastic_ips} ; do
        if [[ ! "${fips_arr[@]}" =~ "${eip}" ]] ; then
            fips_arr=("${fips_arr[@]}" "${eip},None")
        fi
    done
    subnets=`openstack subnet list | awk '/public/ {print($8)}'`
    # associate/disassociate fips
    for fip in ${fips_arr[@]} ; do
        floating_ip=`echo ${fip} | cut -d ',' -f 1`
        fixed_ip=`echo ${fip} | cut -d ',' -f 2`
        floating_ip_subnet=''
        for sn in $subnets ; do
            matched=`python -c "import netaddr; print(netaddr.IPAddress('${floating_ip}') in netaddr.IPNetwork('${sn}'))"`
            if [[ "${matched}" == 'True' ]] ; then
                floating_ip_subnet=${sn}
                break
            fi
        done
        if [[ -z "${floating_ip_subnet}" ]] ; then
            echo WARN: Cant find subnet for floating IP ${floating_ip}, subnets=${subnets}
            continue
        fi
        if [[ "${fixed_ip}" != 'None' ]] ; then
            vm_uuid=`echo "${instances}" | grep "${fixed_ip}" | awk '{print $2}'`
            ${FIP_ASSOCIATE_SCRIPT} ${vm_uuid} ${floating_ip} ${floating_ip_subnet} || /bin/true
        else
            # cleanup rules and vgw for dis-associated fips
            for n in ${compute_nodes} ; do
                SSH_NODE_ADDRESS=${n} ${FIP_DISASSOCIATE_SCRIPT} ${floating_ip} ${floating_ip_subnet} || /bin/true
            done
        fi
    done

    sleep 2
done
