#!/bin/bash -e

iface=$1

if ! grep -q "iface $iface inet static" ./50-cloud-init.cfg ; then
  echo "ERROR: static interface $iface couldn't be found in ./50-cloud-init.cfg"
  cat ./50-cloud-init.cfg
  exit 1
fi

address=`ip addr show $iface | awk '/inet /{print $2}' | cut -d '/' -f 1`
gw=`route -n | grep "^0\.0\.0\.0.*${iface}$" | awk '{print $2}'`

sed -i "s/<address>/$address/g" ./50-cloud-init.cfg
if [[ -n "$gw" ]]; then
  sed -i "s/#gw <gw>/gw $gw/g" ./50-cloud-init.cfg
fi

sudo cp ./50-cloud-init.cfg /etc/network/interfaces.d/50-cloud-init.cfg
series=`lsb_release -cs`
if [[ "$series" == 'trusty' ]]; then
  # '50-cloud-init.cfg' is default name for xenial and it is overwritten
  sudo rm /etc/network/interfaces.d/eth0.cfg
fi

addr_prefix=`echo $address | cut -d '.' -f 1,2,3`
echo "supersede routers $addr_prefix.1;" | sudo tee -a /etc/dhcp/dhclient.conf
