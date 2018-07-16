#!/bin/bash -e

iface=$1
cfg_file='/etc/network/interfaces.d/50-cloud-init.cfg'

address=`ifconfig $iface | grep -o "inet addr:[\.0-9]*" | cut -d ':' -f 2`
netmask=`ifconfig $iface | grep -o "Mask:[\.0-9]*" | cut -d ':' -f 2`
ns=`grep nameserver /etc/resolv.conf | sed 's/nameserver //m'`
gw=`route -n | awk '$1 == "0.0.0.0" { print $2 }'`

dhcp_settings="iface $iface inet dhcp"
manual_settings="iface $iface inet static\n    address $address\n    netmask $netmask\n    dns-nameservers $ns\n    post-up   route add -net 100.80.39.0 netmask 255.255.255.0 gw $gw metric 0 || true\n    post-down route del -net 100.80.39.0 netmask 255.255.255.0 gw $gw metric 0 || true"

sed -e "s/$dhcp_settings/$manual_settings/g" 50-cloud-init.cfg > $cfg_file
