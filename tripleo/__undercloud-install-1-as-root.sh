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

((addr=176+NUM*10))
prov_ip="192.168.$addr"
((addr=172+NUM*10))
mgmt_ip="192.168.$addr"

# Workaround of the problem with GPG keys in openstack-beta rhel repo
#   Public key for NetworkManager-config-server-1.10.2-14.el7_5.noarch.rpm is not installed
#   Public key for heat-cfntools-1.3.0-2.el7ost.noarch.rpm is not installed
#   Public key for ovirt-guest-agent-common-1.0.14-3.el7ev.noarch.rpm is not installed
#   --------------------------------------------------------------------------------
#   Total                                              8.0 MB/s | 157 MB  00:19
#   Retrieving key from file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-beta
#   Importing GPG key 0xF21541EB:
#    Userid     : "Red Hat, Inc. (beta key 2) <security@redhat.com>"
#    Fingerprint: b08b 659e e86a f623 bc90 e8db 938a 80ca f215 41eb
#    Package    : redhat-release-server-7.5-8.el7.x86_64 (installed)
#    From       : /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-beta
#   Importing GPG key 0x897DA07A:
#    Userid     : "Red Hat, Inc. (Beta Test Software) <rawhide@redhat.com>"
#    Fingerprint: 17e8 543d 1d4a a5fa a96a 7e9f fd37 2689 897d a07a
#    Package    : redhat-release-server-7.5-8.el7.x86_64 (installed)
#    From       : /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-beta
#
# Public key for python2-markupsafe-0.23-16.el7ost.x86_64.rpm is not installed
#
# Failing package is: python2-markupsafe-0.23-16.el7ost.x86_64
# GPG Keys are configured as: file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-beta
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release

# update OS
yum update -y

if [[ "$ENVIRONMENT_OS" == 'centos' ]] ; then
  yum install -y epel-release
fi

# install utils & ntpd - it is needed for correct work of OS services
# (particulary neutron services may not work properly)
# libguestfs-tools - is for virt-customize tool for overcloud image customization - enabling repos
yum install -y  ntp wget yum-utils screen mc deltarpm createrepo bind-utils sshpass \
                gcc make python-devel yum-plugin-priorities sshpass libguestfs-tools
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
[ -f $RHEL_ACCOUNT_FILE ] && chown stack:stack $RHEL_ACCOUNT_FILE && mv $RHEL_ACCOUNT_FILE /home/stack/
base_img='/root/overcloud-base-image.qcow2'
[ -f $base_img ] && chown stack:stack $base_img && mv $base_img /home/stack/

# ssh config to do not check host keys and avoid garbadge in known hosts files
cat <<EOF >/home/stack/.ssh/config
Host *
StrictHostKeyChecking no
UserKnownHostsFile=/dev/null
EOF
chown stack:stack /home/stack/.ssh/config
chmod 644 /home/stack/.ssh/config

# install pip for future run of OS checks
curl "https://bootstrap.pypa.io/get-pip.py" -o "get-pip.py"
python get-pip.py
pip install -q virtualenv

# add OpenStack repositories for centos, for rhel it is added in images
if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  echo "INFO: install latest readhat images"
  yum-config-manager --enable rhelosp-rhel-7-server-opt
  yum install -y rhosp-director-images rhosp-director-images-ipa
else
  tripeo_repos=`python -c 'import requests;r = requests.get("https://trunk.rdoproject.org/centos7-queens/current"); print r.text ' | grep python2-tripleo-repos | awk -F"href=\"" '{print $2}' | awk -F"\"" '{print $1}'`
  yum install -y https://trunk.rdoproject.org/centos7-queens/current/${tripeo_repos}
  tripleo-repos -b $OPENSTACK_VERSION current
  # in new centos a variable is introduced,
  # so it is needed to have it because  yum repos
  # started using it.
  if [[ ! -f  /etc/yum/vars/contentdir ]] ; then
    echo centos > /etc/yum/vars/contentdir
  fi
fi

# install tripleo clients
#   osp10 has no preinstalled openstack-utils
yum -y install python-tripleoclient python-rdomanager-oscplugin  openstack-utils

if [[ "$FREE_IPA" == 'true' ]] ; then
  pip install -y novajoin
fi

if [[ "$OPENSTACK_VERSION" == 'ocata' && "$ENVIRONMENT_OS" == 'centos' ]] ; then
  yum update -y
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

if [[ 'newton|ocata' =~ $OPENSTACK_VERSION  ]] ; then
  # Before queens there is RPM based deployement,
  # so prepare RPM repo for contrail
  repo_dir='/var/www/html/contrail'
else
  default_contrail_ver=$(ls -1 /root/contrail_packages | grep -o '\([0-9]\+\.\{0,1\}\)\{1,5\}-[0-9]\+' | sort -nr  | head -n 1)
  CONTRAIL_VERSION=${CONTRAIL_VERSION:-${default_contrail_ver}}
  repo_dir="/var/www/html/${CONTRAIL_VERSION}-${OPENSTACK_VERSION}"
fi

mkdir -p $repo_dir

# prepare contrail packages
rpms=`ls /root/contrail_packages/ | grep "\.rpm"` || true
if [[ -n "$rpms" ]] ; then
  for i in $rpms ; do
    rpm -ivh /root/contrail_packages/${i}
  done
  tar -xvf /opt/contrail/contrail_packages/contrail_rpms.tgz -C $repo_dir
fi

tgzs=`ls /root/contrail_packages/ | grep "\.tgz"` || true
if [[ -n "$tgzs" ]] ; then
  for i in $tgzs ; do
    tar -xvzf /root/contrail_packages/${i} -C $repo_dir
  done
fi

if [[ 'newton|ocata' =~ $OPENSTACK_VERSION  ]] ; then
  update_contrail_repo='no'

  # hack: centos images don have openstack-utilities packages
  # TODO: OSP13: no openstack-utils available in beta
  if [[ "$ENVIRONMENT_OS" == 'centos' || "$OPENSTACK_VERSION" == 'queens' ]] ; then
    case $OPENSTACK_VERSION in
      liberty|mitaka|newton|ocata|pike)
        os_utils_url="http://mirror.comnet.uz/centos/7/cloud/x86_64/openstack-${OPENSTACK_VERSION}/common/openstack-utils-2017.1-1.el7.noarch.rpm"
        ;;
      *)
        os_utils_url="http://mirror.comnet.uz/centos/7/cloud/x86_64/openstack-${OPENSTACK_VERSION}/openstack-utils-2017.1-1.el7.noarch.rpm"
        ;;
    esac
    curl -o ${repo_dir}/openstack-utils-2017.1-1.el7.noarch.rpm $os_utils_url
    update_contrail_repo='yes'
  fi

  # TODO: contrail-vrouter-dpdk depends on liburcu2
  #       temprorary add this package into contrail repo.
  #       It should be fixed by addind the package either into contrail distribution
  #       or into RedHat repo or by enabling additional repo.
  if [[ "$DPDK" != 'off' ]] ; then
    curl -o ${repo_dir}/liburcu2-0.8.6-21.1.x86_64.rpm  http://ftp5.gwdg.de/pub/opensuse/repositories/devel:/tools:/lttng/RedHat_RHEL-5/x86_64/liburcu2-0.8.6-21.1.x86_64.rpm
    # ---
    # workaround problem of dependency python-opencontrail-vrouter-netns-4.1.2.0-163.el7.x86_64 on this
    # packages for dpdk case. package is installed earlier - before rhel registration done and repos are enabled
    curl -o ${repo_dir}/python-websocket-client-0.32.0-116.el7.noarch.rpm http://mirror.centos.org/centos/7/extras/x86_64/Packages/python-websocket-client-0.32.0-116.el7.noarch.rpm   
    curl -o ${repo_dir}/python-docker-py-1.10.6-4.el7.noarch.rpm http://mirror.centos.org/centos/7/extras/x86_64/Packages/python-docker-py-1.10.6-4.el7.noarch.rpm
    curl -o ${repo_dir}/python-docker-pycreds-1.10.6-3.el7.noarch.rpm http://mirror.centos.org/centos/7/extras/x86_64/Packages/python-docker-pycreds-1.10.6-3.el7.noarch.rpm
    # ---
    update_contrail_repo='yes'
  fi

  # WORKAROUND to bug #1767456
  # TODO: remove net-snmp after fix bug #1767456
    cp /root/contrail_packages/net-snmp/* ${repo_dir}
    update_contrail_repo='yes'

  if [[ "$update_contrail_repo" != 'no' ]] ; then
    createrepo --update -v $repo_dir
  fi
else
  # Starting from queens there is container based deployement
  usermod -aG docker stack || true
  pushd $repo_dir
  rm -rf repodata
  createrepo . || echo "WARNING: failed to create repo, containers build may fail."
  popd
fi

# setup undercloud
cp "$my_dir/__undercloud-install-2-as-stack-user.sh" /home/stack/
chown stack:stack /home/stack/__undercloud-install-2-as-stack-user.sh
cp "$my_dir/functions" /home/stack/
chown stack:stack /home/stack/functions

env_opts="NUM=$NUM NETDEV=$NETDEV OPENSTACK_VERSION=$OPENSTACK_VERSION"
env_opts+=" ENVIRONMENT_OS=$ENVIRONMENT_OS ENVIRONMENT_OS_VERSION=$ENVIRONMENT_OS_VERSION"
env_opts+=" TLS=$TLS DPDK=$DPDK TSN=$TSN SRIOV=$SRIOV"
env_opts+=" RHEL_CERT_TEST=$RHEL_CERT_TEST RHEL_ACCOUNT_FILE=$RHEL_ACCOUNT_FILE"
env_opts+=" FREE_IPA=$FREE_IPA CLOUD_DOMAIN_NAME=$CLOUD_DOMAIN_NAME"


if [[ "$FREE_IPA" == 'true' ]] ; then
  otp=$(/usr/lib/python2.7/site-packages/usr/libexec/novajoin-ipa-setup \
    --principal admin \
    --password qwe123QWE \
    --server ${prov_ip}.4 \
    --realm ${CLOUD_DOMAIN_NAME^^} \
    --domain ${CLOUD_DOMAIN_NAME} \
    --hostname $(hostname -f) \
    --precreate)
  echo $otp > ~/free_ipa_otp
  env_opts+=" FREE_IPA_OTP='$otp'"
fi

if [[ "$CLEAN_ENV" == 'create_vms_only' ]]  ; then
  echo "INFO: CLEAN_ENV=$CLEAN_ENV, undercloud setup is not finished."
  echo "      To continue undercloud setup run:"
  echo "      sudo -u stack $env_opts /home/stack/__undercloud-install-2-as-stack-user.sh"
  exit 0
fi

sudo -u stack $env_opts /home/stack/__undercloud-install-2-as-stack-user.sh

# increase timeouts due to virtual installation
openstack-config --set /etc/nova/nova.conf DEFAULT rpc_response_timeout 600
openstack-config --set /etc/nova/nova.conf DEFAULT dhcp_domain $CLOUD_DOMAIN_NAME
openstack-config --set /etc/ironic/ironic.conf DEFAULT rpc_response_timeout 600
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

# disable selinux
setenforce 0 || true
sed -i "s/SELINUX=.*/SELINUX=disabled/g" /etc/selinux/config  || true
getenforce  || true
cat /etc/selinux/config  || true
