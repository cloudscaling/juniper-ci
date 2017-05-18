#!/bin/bash -eux


export SSH_KEY=${SSH_KEY:-''}

if [[ -z "$vm_uuid" ]] ; then
    echo "vm_uuid should be first parameter"
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

function add_fip_vgw_subnets() {
    local vgw_subnets=$1
    ${ssh_cmd} sudo python /opt/contrail/utils/provision_vgw_interface.py \
        --oper create --interface vgw --subnets "${vgw_subnets}" --routes 0.0.0.0/0 \
        --vrf default-domain:admin:public:public
    #Workarraund for sandbox because provision_vgw_interface.py uses 'route add' that cant work with /32 mask
    for i in ${vgw_subnets} ; do
        if ! ${ssh_cmd} sudo ip route show ${i} | grep -q vgw ; then
            ${ssh_cmd} sudo ip route add ${i} dev vgw
        fi
    done
}

function remove_fip_vgw_subnets() {
    local fip=$1
    if ${ssh_cmd} sudo ip route show ${fip}/32 | grep -q vgw ; then
        ${ssh_cmd} sudo ip route del ${fip}/32 dev vgw
    fi
}

function ensure_ip_forwarding() {
    ${ssh_cmd} sudo sysctl net.ipv4.ip_forward=1
    if ! ${ssh_cmd} sudo iptables -C FORWARD -i vhost0 -o vgw -j ACCEPT ; then
        ${ssh_cmd} sudo iptables -A FORWARD -i vhost0 -o vgw -j ACCEPT
    fi
    if ! ${ssh_cmd} sudo iptables -C FORWARD -i vgw -o vhost0 -j ACCEPT ; then
        ${ssh_cmd} sudo iptables -A FORWARD -i vgw -o vhost0 -j ACCEPT
    fi
}
