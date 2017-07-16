#!/bin/bash -ex

# this script file should be copied to undercloud machine and run there.

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [[ -z "$NUM" ]] ; then
  echo "Please set NUM variable to specific environment wber. (export NUM=4)"
  exit 1
fi

if [[ -z "$OPENSTACK_VERSION" ]] ; then
  echo "OPENSTACK_VERSION is expected (e.g. export OPENSTACK_VERSION=newton)"
  exit 1
fi

if [[ -z "$ENVIRONMENT_OS" ]] ; then
  echo "ENVIRONMENT_OS is expected (e.g. export ENVIRONMENT_OS=centos)"
  exit 1
fi

NETDEV=${NETDEV:-'eth1'}
CLOUD_DOMAIN_NAME=${CLOUD_DOMAIN_NAME:-'localdomain'}

# allow ip forwarding
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p /etc/sysctl.conf
# set static hostname
hostnamectl set-hostname myhost.my${NUM}domain
hostnamectl set-hostname --transient myhost.my${NUM}domain
echo "127.0.0.1   localhost myhost myhost.my${NUM}domain" > /etc/hosts
systemctl restart network

# update OS
yum update -y

# install ntpd - it is needed for correct work of OS services
# (particulary neutron services may not work properly)
yum install -y ntp wget
chkconfig ntpd on
service ntpd start

# create stack user
if ! grep -q 'stack' /etc/passwd ; then
  useradd -m stack -s /bin/bash
else
  echo User stack is already exist
fi
echo "stack:password" | chpasswd
echo "stack ALL=(root) NOPASSWD:ALL" | tee -a /etc/sudoers.d/stack
chmod 0440 /etc/sudoers.d/stack
mkdir -p /home/stack/.ssh
chown stack:stack /home/stack/.ssh
chmod 700 /home/stack/.ssh
# key to stack user may access kvm host
cp /root/stack_id_rsa /home/stack/.ssh/id_rsa
cp /root/stack_id_rsa.pub /home/stack/.ssh/id_rsa.pub
chown stack:stack /home/stack/.ssh/id_rsa
chown stack:stack /home/stack/.ssh/id_rsa.pub
chmod 600 /home/stack/.ssh/id_rsa
chmod 644 /home/stack/.ssh/id_rsa.pub
# ssh config to do not check host keys and avoid garbadge in known hosts files
cat <<EOF >/home/stack/.ssh/config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOF
chown stack:stack /home/stack/.ssh/config
chmod 644 /home/stack/.ssh/config

# install useful utils
yum install -y yum-utils screen mc deltarpm createrepo bind-utils
# add OpenStack repositories for centos, for rhel it is added in images
if [[ "$ENVIRONMENT_OS" != 'rhel' ]] ; then
  curl -L -o /etc/yum.repos.d/delorean-$OPENSTACK_VERSION.repo https://trunk.rdoproject.org/centos7-$OPENSTACK_VERSION/current/delorean.repo
  curl -L -o /etc/yum.repos.d/delorean-deps-$OPENSTACK_VERSION.repo http://trunk.rdoproject.org/centos7-$OPENSTACK_VERSION/delorean-deps.repo
fi
# install tripleo clients
yum -y install yum-plugin-priorities python-tripleoclient python-rdomanager-oscplugin sshpass openstack-utils

# add Ceph repos to workaround bug with redhat-lsb-core package
# todo: there is enabled ceph repo jewel
#yum -y install --enablerepo=extras centos-release-ceph-hammer
#sed -i -e 's%gpgcheck=.*%gpgcheck=0%' /etc/yum.repos.d/CentOS-Ceph-Hammer.repo

# another hack to avoid 'sudo: require tty' error
sed -i -e 's/Defaults[ \t]*requiretty.*/#Defaults    requiretty/g' /etc/sudoers

cp "$my_dir/__undercloud-install-2-as-stack-user.sh" /home/stack/
chown stack:stack /home/stack/__undercloud-install-2-as-stack-user.sh
sudo -u stack NUM=$NUM NETDEV=$NETDEV OPENSTACK_VERSION=$OPENSTACK_VERSION ENVIRONMENT_OS=$ENVIRONMENT_OS /home/stack/__undercloud-install-2-as-stack-user.sh

# increase timeouts due to virtual installation
openstack-config --set /etc/nova/nova.conf DEFAULT rpc_response_timeout 600
openstack-config --set /etc/nova/nova.conf DEFAULT dhcp_domain $CLOUD_DOMAIN_NAME
openstack-config --set /etc/ironic/ironic.conf DEFAULT rpc_response_timeout 600
openstack-config --set /etc/neutron/neutron.conf DEFAULT  dns_domain $CLOUD_DOMAIN_NAME

# despite the field is depricated it is still important to set it
# https://bugs.launchpad.net/neutron/+bug/1657814
if grep -q '^dhcp_domain.*=' /etc/neutron/dhcp_agent.ini ; then
  sed -i "s/^dhcp_domain.*=.*/dhcp_domain = ${CLOUD_DOMAIN_NAME}/" /etc/neutron/dhcp_agent.ini
else
  sed -i "/^#.*dhcp_domain.*=/a dhcp_domain = ${CLOUD_DOMAIN_NAME}" /etc/neutron/dhcp_agent.ini
fi

openstack-service restart neutron
openstack-service restart ironic
openstack-service restart nova


# prepare contrail packages
for i in `ls /root/contrail_packages/*.rpm` ; do
  rpm -ivh ${i}
done
mkdir -p /var/www/html/contrail
tar -zxvf /opt/contrail/contrail_packages/contrail_rpms.tgz -C /var/www/html/contrail

# hack: centos images don have openstack-utilities packages
wget -P /var/www/html/contrail  http://mirror.comnet.uz/centos/7/cloud/x86_64/openstack-newton/common/openstack-utils-2017.1-1.el7.noarch.rpm
createrepo --update -v /var/www/html/contrail

# prepare docker images
for i in `ls /root/contrail_packages/*.tgz` ; do
  tar -zxvf ${i} -C /var/www/html/contrail
done
