#!/bin/bash -ex

# tune some host settings
sysctl -w vm.max_map_count=1048575

registry_ip=${1:-localhost}
if [[ "$registry_ip" != 'localhost' ]] ; then
  mkdir -p /etc/docker
  cat <<EOF > /etc/docker/daemon.json
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
  apt-get -y update
  DEBIAN_FRONTEND=noninteractive apt-get -fy -o Dpkg::Options::="--force-confnew" upgrade
  apt-get install -y --no-install-recommends mc git wget ntp ntpdate python-pip
elif [ "x$HOST_OS" == "xcentos" ]; then
  # ip is located in /usr/sbin that is not in path...
  export PATH=${PATH}:/usr/sbin

  yum install -y epel-release
  yum install -y mc git wget ntp python-pip

  systemctl enable ntpd.service
  systemctl start ntpd.service

  # TODO: remove this hack
  #wget -nv http://$registry_ip/$CONTRAIL_VERSION-$OPENSTACK_VERSION/vrouter.ko
  #chmod 755 vrouter.ko
  #insmod ./vrouter.ko
fi

pip install -U pip
if [ "x$HOST_OS" == "xubuntu" ]; then
  apt-get install -y python-dev libffi-dev gcc libssl-dev python-selinux
  pip install -U ansible
elif [ "x$HOST_OS" == "xcentos" ]; then
  yum install -y python-devel libffi-devel gcc openssl-devel libselinux-python
  yum install -y ansible
fi
pip install kolla-ansible
if [ "x$HOST_OS" == "xubuntu" ]; then
  cp -r /usr/local/share/kolla-ansible/etc_examples/kolla /etc/kolla/
  cp /usr/local/share/kolla-ansible/ansible/inventory/* .
elif [ "x$HOST_OS" == "xcentos" ]; then
  cp -r /usr/share/kolla-ansible/etc_examples/kolla /etc/kolla/
  cp /usr/share/kolla-ansible/ansible/inventory/* .
fi
# TODO: write network interface and other params dynamically depends on OS. or create two files for CentOS and Ubuntu.
cp global.yml /etc/kolla

kolla-genpwd
kolla-ansible -i all-in-one bootstrap-servers
kolla-ansible pull -i all-in-one
docker images

mkdir -p /etc/kolla/config/nova
cat <<EOF > /etc/kolla/config/nova/nova-compute.conf
[libvirt]
virt_type = qemu
cpu_mode = none
EOF

kolla-ansible prechecks -i /path/to/all-in-one
kolla-ansible deploy -i /path/to/all-in-one
docker ps -a
kolla-ansible post-deploy


#TODO: add kolla here

exit $err
