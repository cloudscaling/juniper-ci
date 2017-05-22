#!/bin/bash -eux


export SSH_KEY=${SSH_KEY:-''}

if [[ -z "$vm_uuid" && -z "$SSH_NODE_ADDRESS" ]] ; then
    echo "Either vm_uuid or SSH_NODE_ADDRESS is expected"
    exit -1
fi

if [[ -n "$SSH_KEY" ]] ; then
    ssh_opts="-i $SSH_KEY"
else
    ssh_opts = ''
fi
ssh_user=${SSH_USER:-'ubuntu'}
ssh_opts+=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ssh_node=${SSH_NODE_ADDRESS:-`openstack server show $vm_uuid | awk '/OS-EXT-SRV-ATTR:host/ {print $4}'`}
if [[ -z "$ssh_node" ]] ; then
    echo "FATAL: failed to find compute node by uuid $vm_uuid"
    exit -1
fi
ssh_cmd="ssh ${ssh_opts} ${ssh_user}@${ssh_node}"

primary_private_ip=`$ssh_cmd sudo ifconfig vhost0 | grep -o -P '(?<=addr:).*(?=  Bcast)'`
if [[ -z "$primary_private_ip" ]] ; then
    echo "FATAIL: failed to get primary private ip address for vhost0, there is no vrouter on the host"
    $ssh_cmd sudo ifconfig vhost0
    exit -1
fi
secondary_private_ips=(`$ssh_cmd sudo ifconfig | grep -v ${primary_private_ip} | grep 'inet addr' | grep -o -P '(?<=addr:).*(?=  Bcast)'`)


function cleanup_odd_rules_from_iptables() {
    local fip=$1
    local secondary_private_ip=$2
    local chains=("PREROUTING" "POSTROUTING")
    for c in ${chains[@]} ; do
        local rule=`${ssh_cmd} sudo iptables -t nat -S ${c} | grep "${fip}" | grep -v "${secondary_private_ip}" | grep -o -P "(?<=-A ).*"`
        if [[ -n "${rule}" ]] ; then
            ${ssh_cmd} sudo iptables -t nat -D ${rule}
        fi
    done
}

function add_rule_to_iptables() {
    local fip=$1
    local secondary_private_ip=$2
    if ! ${ssh_cmd} sudo iptables -t nat -C PREROUTING -d ${secondary_private_ip}/32 -j DNAT --to-destination ${fip} ; then
        ${ssh_cmd} sudo iptables -t nat -A PREROUTING -d ${secondary_private_ip}/32 -j DNAT --to-destination ${fip}
    fi
    if ! ${ssh_cmd} sudo iptables -t nat -C POSTROUTING -s ${fip}/32 -j SNAT --to-source ${secondary_private_ip} ; then
        ${ssh_cmd} sudo iptables -t nat -A POSTROUTING -s ${fip}/32 -j SNAT --to-source ${secondary_private_ip}
    fi
}

function del_rule_from_iptables() {
    local fip=$1
    local secondary_private_ip=$2
    if ${ssh_cmd} sudo iptables -t nat -C PREROUTING -d ${secondary_private_ip}/32 -j DNAT --to-destination ${fip} ; then
        ${ssh_cmd} sudo iptables -t nat -D PREROUTING -d ${secondary_private_ip}/32 -j DNAT --to-destination ${fip}
    fi
    if ${ssh_cmd} sudo iptables -t nat -C POSTROUTING -s ${fip}/32 -j SNAT --to-source ${secondary_private_ip} ; then
        ${ssh_cmd} sudo iptables -t nat -D POSTROUTING -s ${fip}/32 -j SNAT --to-source ${secondary_private_ip}
    fi
}

function remove_ip_forwarding() {
    local dev_name=$1
    if ${ssh_cmd} sudo iptables -C FORWARD -i vhost0 -o ${dev_name} -j ACCEPT ; then
        ${ssh_cmd} sudo iptables -D FORWARD -i vhost0 -o ${dev_name} -j ACCEPT
    fi
    if ${ssh_cmd} sudo iptables -C FORWARD -i ${dev_name} -o vhost0 -j ACCEPT ; then
        ${ssh_cmd} sudo iptables -D FORWARD -i ${dev_name} -o vhost0 -j ACCEPT
    fi
}

function ensure_ip_forwarding() {
    local dev_name=$1
    ${ssh_cmd} sudo sysctl net.ipv4.ip_forward=1
    if ! ${ssh_cmd} sudo iptables -C FORWARD -i vhost0 -o ${dev_name} -j ACCEPT ; then
        ${ssh_cmd} sudo iptables -A FORWARD -i vhost0 -o ${dev_name} -j ACCEPT
    fi
    if ! ${ssh_cmd} sudo iptables -C FORWARD -i ${dev_name} -o vhost0 -j ACCEPT ; then
        ${ssh_cmd} sudo iptables -A FORWARD -i ${dev_name} -o vhost0 -j ACCEPT
    fi
}

function remove_fip_vgw_subnets() {
    local fip=$1
    local dev_name="vgw`echo $fip | tr -d '.'`"
    local subnet="${fip}/32"
    if ${ssh_cmd} sudo ifconfig ${dev_name} ; then
        ${ssh_cmd} sudo python /opt/contrail/utils/provision_vgw_interface.py \
            --oper delete --interface ${dev_name} --subnets ${subnet} --routes 0.0.0.0/0 \
            --vrf default-domain:admin:public:public
    fi
    local current_route=`${ssh_cmd} sudo ip route show ${subnet}`
    if echo "${current_route}" | grep -q ${dev_name} ; then
        ${ssh_cmd} sudo ip route del ${subnet} dev ${dev_name}
    fi
    remove_ip_forwarding ${dev_name}
}

function ensure_fip_vgw_subnets() {
    local fip=$1
    local dev_name="vgw`echo ${fip} | tr -d '.'`"
    local subnet="${fip}/32"
    if ! ${ssh_cmd} sudo ifconfig ${dev_name} ; then
        ${ssh_cmd} sudo python /opt/contrail/utils/provision_vgw_interface.py \
            --oper create --interface ${dev_name} --subnets ${subnet} --routes 0.0.0.0/0 \
            --vrf default-domain:admin:public:public
    fi
    #Workarraund for sandbox because provision_vgw_interface.py uses 'route add' that cant work with /32 mask
    local current_route=`${ssh_cmd} sudo ip route show ${subnet}`
    if ! echo "${current_route}" | grep -q ${dev_name} ; then
        ${ssh_cmd} sudo ip route add ${subnet} dev ${dev_name}
    fi
    ensure_ip_forwarding ${dev_name}
}
