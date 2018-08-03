#!/bin/bash -e

main_net_prefix=$1
vhost_address=$2

sed -i "s/<address>/$vhost_address/g" ./50-cloud-init.cfg

sudo cp ./50-cloud-init.cfg /etc/network/interfaces.d/50-cloud-init.cfg
series=`lsb_release -cs`
if [[ "$series" == 'trusty' ]]; then
  # '50-cloud-init.cfg' is default name for xenial and it is overwritten
  sudo rm /etc/network/interfaces.d/eth0.cfg
fi

# this should be done for first interface!
echo "supersede routers $main_net_prefix.1;" | sudo tee -a /etc/dhcp/dhclient.conf
