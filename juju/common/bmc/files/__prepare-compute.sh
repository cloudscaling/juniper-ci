#!/bin/bash -ex

main_net_prefix=$1
vhost_address=$2

function do_trusty() {
  add-apt-repository -y cloud-archive:mitaka &>>apt.log
  apt-get update &>>apt.log
  cat >/etc/network/interfaces.d/50-cloud-init.cfg <<EOF
# The primary network interface
auto eth0
iface eth0 inet dhcp

auto eth1
iface eth1 inet static
    address $vhost_address
    netmask 255.255.255.0
    post-up  route add -net 192.168.39.0 netmask 255.255.255.0 dev eth1 metric 10 || true
    pre-down route del -net 192.168.39.0 netmask 255.255.255.0 dev eth1 metric 10 || true
    post-up  ip route add 192.168.38.0/24 dev eth1 metric 10 || true
    pre-down ip route del 192.168.38.0/24 dev eth1 metric 10 || true
    post-up  ip r add 192.168.37.0/24 dev \$IFACE metric 10 || true
    pre-down ip r del 192.168.37.0/24 dev \$IFACE metric 10 || true
EOF
  # '50-cloud-init.cfg' is default name for xenial and it is overwritten
  rm /etc/network/interfaces.d/eth0.cfg
}

function do_xenial() {
  cat >/etc/network/interfaces.d/50-cloud-init.cfg <<EOF
# This file is generated from information provided by
# the datasource.  Changes to it will not persist across an instance.
# To disable cloud-init's network configuration capabilities, write a file
# /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg with the following:
# network: {config: disabled}
auto lo
iface lo inet loopback

auto ens3
iface ens3 inet dhcp

auto ens4
iface ens4 inet static
    address $vhost_address
    netmask 255.255.255.0
    post-up  route add -net 192.168.39.0 netmask 255.255.255.0 dev ens4 metric 10 || true
    pre-down route del -net 192.168.39.0 netmask 255.255.255.0 dev ens4 metric 10 || true
    post-up  ip route add 192.168.38.0/24 dev ens4 metric 10 || true
    pre-down ip route del 192.168.38.0/24 dev ens4 metric 10 || true
    post-up  ip r add 192.168.37.0/24 dev \$IFACE metric 10 || true
    pre-down ip r del 192.168.37.0/24 dev \$IFACE metric 10 || true
EOF
}

function do_bionic() {
  rm /etc/resolv.conf
  ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
}

series=`lsb_release -cs`
do_$series

kernel_version=`uname -r | tr -d '\r'`
if [[ "$SERIES" == 'bionic' ]]; then
  dpdk_req="linux-modules-extra-$kernel_version"
else
  dpdk_req="linux-image-extra-$kernel_version"
fi
apt-get -fy install $dpdk_req dpdk apparmor-profiles &>>apt.log

# this should be done for first interface!
echo "supersede routers $main_net_prefix.1;" >> /etc/dhcp/dhclient.conf
