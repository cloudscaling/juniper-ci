#!/bin/bash -ex

# tune some host settings
sudo sysctl -w vm.max_map_count=1048575

registry_ip=${1:-localhost}
if [[ "$registry_ip" != 'localhost' ]] ; then
  sudo mkdir -p /etc/docker
  cat | sudo tee /etc/docker/daemon.json << EOF
{
    "insecure-registries": ["$registry_ip:5000"]
}
EOF
fi

if [[ -x $(command -v apt-get 2>/dev/null) ]]; then
  HOST_OS='ubuntu'
elif [[ -x $(command -v yum 2>/dev/null) ]]; then
  HOST_OS='centos'
else
  echo "ERROR: Unable to find apt-get or yum"
  exit 1
fi

echo "INFO: Preparing instances"
if [ "x$HOST_OS" == "xubuntu" ]; then
  sudo apt-get -y update
  sudo DEBIAN_FRONTEND=noninteractive apt-get -fy -o Dpkg::Options::="--force-confnew" upgrade
  sudo apt-get install -y --no-install-recommends mc git wget ntp ntpdate
elif [ "x$HOST_OS" == "xcentos" ]; then
  # ip is located in /usr/sbin that is not in path...
  export PATH=${PATH}:/usr/sbin

  sudo yum install -y epel-release
  sudo yum install -y mc git wget ntp

  sudo systemctl enable ntpd.service
  sudo systemctl start ntpd.service

  # TODO: remove this hack
  #wget -nv http://$registry_ip/$CONTRAIL_VERSION-$OPENSTACK_VERSION/vrouter.ko
  #chmod 755 vrouter.ko
  #sudo insmod ./vrouter.ko
fi

#TODO: add kolla here

exit $err
