#!/bin/bash -e

iface=$1
addr=$2

address=`ifconfig $iface | grep -o "inet addr:[\.0-9]*" | cut -d ':' -f 2`
netmask=`ifconfig $iface | grep -o "Mask:[\.0-9]*" | cut -d ':' -f 2`
gw=`route -n | awk '$1 == "0.0.0.0" { print $2 }'`

sed -i "s/<address>/$address/g" 50-cloud-init.cfg
sed -i "s/<netmask>/$netmask/g" 50-cloud-init.cfg
sed -i "s/<gw>/$gw/g" 50-cloud-init.cfg

sudo cp ./50-cloud-init.cfg /etc/network/interfaces.d/50-cloud-init.cfg
series=`lsb_release -cs`
if [[ "$series" == 'trusty' ]]; then
  # '50-cloud-init.cfg' is default name for xenial and it is overwritten
  sudo rm /etc/network/interfaces.d/eth0.cfg
fi
echo "supersede routers $addr.1;" | sudo tee -a /etc/dhcp/dhclient.conf
