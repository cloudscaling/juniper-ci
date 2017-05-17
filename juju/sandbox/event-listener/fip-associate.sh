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

    for i in {1..2} ; do
        # the 0 - is primary private ip, so skip it
        sp_ip=`aws ec2 describe-instances \
            --filter "Name=private-ip-address,Values=${primary_private_ip}" \
            --query "Reservations[*].Instances[*].NetworkInterfaces[*].PrivateIpAddresses[${i}]"`
        if [[ ! sp_ip =~ 'Association' ]] ; then
            secondary_private_ip=`echo ${sp_ip} | grep -o -P '(?<=PrivateIpAddress": ")[0-9\.]+(?=")'`
        else
            if [[ -n $"vgw_subnets" ]] ; then
                vgw_subnets+=' '
            fi
            vgw_subnets+="`echo ${sp_ip}| grep -o -P '(?<=PublicIp": ")[0-9\.]+(?=")'`/32"
        fi
    done

    if [[ -z "$secondary_private_ip" ]] ; then
        echo "FATAL: there is no free secondary private ip address"
        exit -1
    fi

    aws ec2 associate-address --allow-reassociation \
        --network-interface-id ${iface_id} \
        --allocation-id ${fip_allocation_id} \
        --private-ip-address ${secondary_private_ip}
else
    secondary_private_ip=$fip_private_address
fi


# always cgeck that vgw is created and iptables and routes are set

add_rule_to_iptables ${fip} ${secondary_private_ip}

if [[ -n $"vgw_subnets" ]] ; then
    vgw_subnets+=' '
fi
vgw_subnets+="${fip}/32"
add_fip_vgw_subnets ${vgw_subnets}
