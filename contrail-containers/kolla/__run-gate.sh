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

kolla_path=''
if [[ -x $(command -v apt-get 2>/dev/null) ]]; then
  HOST_OS='ubuntu'
  kolla_path='/usr/local/share'
  sed -i -e "s/{{if1}}/ens3/g" globals.yml
  sed -i -e "s/{{if2}}/ens4/g" globals.yml
elif [[ -x $(command -v yum 2>/dev/null) ]]; then
  HOST_OS='centos'
  kolla_path='/usr/share'
  sed -i -e "s/{{if1}}/eth0/g" globals.yml
  sed -i -e "s/{{if2}}/eth1/g" globals.yml
else
  echo "ERROR: Unable to find apt-get or yum"
  exit 1
fi
sed -i -e "s/{{base_distro}}/$HOST_OS/g" globals.yml
sed -i -e "s/{{openstack_version}}/$OPENSTACK_VERSION/g" globals.yml

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
cp -r $kolla_path/kolla-ansible/etc_examples/kolla /etc/kolla/
cp $kolla_path/kolla-ansible/ansible/inventory/* .
cp globals.yml /etc/kolla

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

kolla-ansible prechecks -i all-in-one
kolla-ansible deploy -i all-in-one
docker ps -a
kolla-ansible post-deploy

# test it
pip install python-openstackclient
$kolla_path/kolla-ansible/init-runonce

exit $err
