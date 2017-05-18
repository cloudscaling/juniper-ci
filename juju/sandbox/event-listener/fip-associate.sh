#!/bin/bash -eux

my_file="$(readlink -e "$0")"
my_dir="$(dirname ${my_file})"

vm_uuid=$1
fip=$2

# expects:
#   vm_uuid
#   fip
# adds variables:
#       ssh_cmd
#       primary_private_ip
#       secondary_private_ips
source ${my_dir}/functions.sh



secondary_private_ip=''
vgw_subnets=''
fip_private_address=`aws ec2 describe-addresses --public-ips ${fip} | awk '/PrivateIpAddress/ {print $2}' | sed 's/[",]//g'`
if [[ -z "${fip_private_address}" || ! "${secondary_private_ips[@]}" =~ "${fip_private_address}" ]] ; then

    fip_allocation_id=`aws ec2 describe-addresses --public-ips ${fip} | awk '/AllocationId/ {print $2}' | sed 's/[",]//g'`
    if [[ -z "$fip_allocation_id" ]] ; then
        echo "FATAL: failed to get allocation id for fip ${fip}"
        exit -1
    fi
    iface_id=`aws ec2 describe-instances --filter "Name=private-ip-address,Values=${primary_private_ip}" \
        --query 'Reservations[*].Instances[*].NetworkInterfaces[*].NetworkInterfaceId' --output text`
    if [[ -z "$iface_id" ]] ; then
        echo "FATAL: failed to interface id for instance by private ip address ${primary_private_ip}"
        exit -1
    fi

    free_spips_query='Reservations[*].Instances[*].NetworkInterfaces[*].PrivateIpAddresses[? ! Primary && Association==`null`]'
    free_spips=(`aws ec2 describe-instances \
        --filter "Name=private-ip-address,Values=${primary_private_ip}" \
        --query "${free_spips_query}" \
        --output text | grep -v 'ASSOCIATION' | awk '{print $3}'`)

    if [[ -z "${free_spips[@]}" ]] ; then
        echo "FATAL: there is no free secondary private ip address"
        exit -1
    fi

    # just choose first free secondary ip
    secondary_private_ip=${free_spips[0]}

    # associate fip with free secondary private ip
    aws ec2 associate-address --allow-reassociation \
        --network-interface-id ${iface_id} \
        --allocation-id ${fip_allocation_id} \
        --private-ip-address ${secondary_private_ip}
else
    # fip is already associated with one of secondary private ips => no needs to re-associate
    secondary_private_ip=${fip_private_address}
fi


# always check that vgw is created and iptables and routes are set
cleanup_odd_rules_from_iptables ${fip} ${secondary_private_ip}
add_rule_to_iptables ${fip} ${secondary_private_ip}

# prepare ip routes vgw devices
associated_fips_query='Reservations[*].Instances[*].NetworkInterfaces[*].PrivateIpAddresses[? ! Primary && Association!=`null`].Association.[PublicIp]'
associated_fips=(`aws ec2 describe-instances \
    --filter "Name=private-ip-address,Values=${primary_private_ip}" \
    --query "${associated_fips_query}" \
    --output text | grep -v 'ASSOCIATION' | awk '{print $3}'`)

if [[ -z "${associated_fips[@]}" ]] ; then
    echo "FATAL: there is no associated secondary private ip address"
    exit -1
fi

vgw_subnets=''
for i in ${associated_fips[@]} ; do
    if [[ -n $"vgw_subnets" ]] ; then
        vgw_subnets+=' '
    fi
    vgw_subnets+="${i}/32"
done
add_fip_vgw_subnets ${vgw_subnets}

# always ensure that ip forwarding is enabled
ensure_ip_forwarding
