#!/bin/bash -e

address=$1

sed -i "s/<address>/$address/g" ./50-cloud-init.cfg

sudo cp ./50-cloud-init.cfg /etc/network/interfaces.d/50-cloud-init.cfg
series=`lsb_release -cs`
if [[ "$series" == 'trusty' ]]; then
  # '50-cloud-init.cfg' is default name for xenial and it is overwritten
  sudo rm /etc/network/interfaces.d/eth0.cfg
fi

addr_prefix=`echo $address | cut -d '.' -f 1,2,3`
echo "supersede routers $addr_prefix.1;" | sudo tee -a /etc/dhcp/dhclient.conf
