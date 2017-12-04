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

if [[ -z "$MGMT_IP" ]] ; then
  echo "MGMT_IP is expected"
  exit 1
fi

if [[ -z "$PROV_IP" ]] ; then
  echo "PROV_IP is expected"
  exit 1
fi

if [[ -z "$NETDEV" ]] ; then
  echo "NETDEV is expected (e.g. export NETDEV=eth1)"
  exit 1
fi

CLOUD_DOMAIN_NAME=${CLOUD_DOMAIN_NAME:-'localdomain'}

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
# ssh config to do not check host keys and avoid garbadge in known hosts files
cat <<EOF >/home/stack/.ssh/config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOF
chown stack:stack /home/stack/.ssh/config
chmod 644 /home/stack/.ssh/config

# add OpenStack repositories for centos, for rhel it is added in images
if [[ "$ENVIRONMENT_OS" == 'centos' ]] ; then
  curl -L -o /etc/yum.repos.d/delorean-$OPENSTACK_VERSION.repo https://trunk.rdoproject.org/centos7-$OPENSTACK_VERSION/current/delorean.repo
  curl -L -o /etc/yum.repos.d/delorean-deps-$OPENSTACK_VERSION.repo http://trunk.rdoproject.org/centos7-$OPENSTACK_VERSION/delorean-deps.repo

  yum update -y
fi

# install ntpd - it is needed for correct work of OS services
# (particulary neutron services may not work properly)
# install tripleo clients
yum -y install  ntp wget yum-utils screen mc deltarpm createrepo bind-utils sshpass \
                gcc make python-devel yum-plugin-priorities \
                python-tripleoclient python-rdomanager-oscplugin sshpass openstack-utils

chkconfig ntpd on
service ntpd start

if [[ "$OPENSTACK_VERSION" == 'ocata' && "$ENVIRONMENT_OS" == 'centos' ]] ; then
  # workaround for https://bugs.launchpad.net/tripleo/+bug/1692899
  # correct fix is in the review
  # (https://review.openstack.org/#/c/467248/1/heat-config-docker-cmd/os-refresh-config/configure.d/50-heat-config-docker-cmd)
  mkdir -p /var/run/heat-config
  echo "{}" > /var/run/heat-config/heat-config
  if [[ -f /usr/share/openstack-heat-templates/software-config/elements/heat-config-docker-cmd/os-refresh-config/configure.d/50-heat-config-docker-cmd ]] ; then
    sed -i 's/return 1/return 0/' /usr/share/openstack-heat-templates/software-config/elements/heat-config-docker-cmd/os-refresh-config/configure.d/50-heat-config-docker-cmd
  fi
  if [[ -f /usr/libexec/os-refresh-config/configure.d/50-heat-config-docker-cmd ]] ; then
    sed -i 's/return 1/return 0/' /usr/libexec/os-refresh-config/configure.d/50-heat-config-docker-cmd
  fi
fi

# add Ceph repos to workaround bug with redhat-lsb-core package
# todo: there is enabled ceph repo jewel
#yum -y install --enablerepo=extras centos-release-ceph-hammer
#sed -i -e 's%gpgcheck=.*%gpgcheck=0%' /etc/yum.repos.d/CentOS-Ceph-Hammer.repo

# another hack to avoid 'sudo: require tty' error
sed -i -e 's/Defaults[ \t]*requiretty.*/#Defaults    requiretty/g' /etc/sudoers

cp "$my_dir/__undercloud-install-2-as-stack-user.sh" /home/stack/
chown stack:stack /home/stack/__undercloud-install-2-as-stack-user.sh
env_opts="NUM=$NUM OPENSTACK_VERSION=$OPENSTACK_VERSION"
env_opts+=" ENVIRONMENT_OS=$ENVIRONMENT_OS ENVIRONMENT_OS_VERSION=$ENVIRONMENT_OS_VERSION"
env_opts+=" NETDEV=$NETDEV MGMT_IP=$MGMT_IP PROV_IP=$PROV_IP"
sudo -u stack $env_opts /home/stack/__undercloud-install-2-as-stack-user.sh

# increase timeouts due to virtual installation
openstack-config --set /etc/nova/nova.conf DEFAULT rpc_response_timeout 600
openstack-config --set /etc/nova/nova.conf DEFAULT dhcp_domain $CLOUD_DOMAIN_NAME
openstack-config --set /etc/nova/nova.conf DEFAULT max_concurrent_builds 4

openstack-config --set /etc/ironic/ironic.conf DEFAULT rpc_response_timeout 600
openstack-config --set /etc/ironic/ironic.conf DEFAULT rpc_thread_pool_size 8

openstack-config --set /etc/neutron/neutron.conf DEFAULT  dns_domain $CLOUD_DOMAIN_NAME
openstack-config --set /etc/neutron/neutron.conf DEFAULT rpc_response_timeout 300

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
