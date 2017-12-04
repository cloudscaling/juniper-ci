#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

# common setting from create_env.sh
if [[ -z "$NUM" ]] ; then
  echo "Please set NUM variable to specific environment number. (export NUM=4)"
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

if [[ -z "$PROV_NETDEV" ]] ; then
  echo "PROV_NETDEV is expected"
  exit 1
fi

if [[ -z "$SSH_OPTS" ]] ; then
  echo "SSH_OPTS is expected"
  exit 1
fi

IMAGES=${IMAGES:-"/home/jenkins/overcloud-images/images-${ENVIRONMENT_OS}-${ENVIRONMENT_OS_VERSION}-${OPENSTACK_VERSION}.tar"}
NETDEV=${NETDEV:-${PROV_NETDEV}}

# on kvm host do once: create stack user, create home directory, add him to libvirtd group
ssh_addr_root="root@${MGMT_IP}"
ssh_addr_stack="stack@${MGMT_IP}"

source "$my_dir/../common/virsh/functions"

# copy images for overcloud to it. (images can be build manually but it's too long - use previously built images)
if [ -f $IMAGES ] ; then
  scp $SSH_OPTS -B $IMAGES ${ssh_addr_stack}:/tmp/images.tar
else
  echo "ERROR: image building is not supported"
  exit 1
fi

for fff in __undercloud-install-1-as-root.sh __undercloud-install-2-as-stack-user.sh ; do
  scp $SSH_OPTS -B "$my_dir/$fff" ${ssh_addr_root}:/root/$fff
done
env_opts="NUM=$NUM OPENSTACK_VERSION=$OPENSTACK_VERSION"
env_opts+=" ENVIRONMENT_OS=$ENVIRONMENT_OS ENVIRONMENT_OS_VERSION=$ENVIRONMENT_OS_VERSION"
env_opts+=" NETDEV=$NETDEV MGMT_IP=$MGMT_IP PROV_IP=$PROV_IP SSH_OPTS='$SSH_OPTS'"
ssh -T $SSH_OPTS $ssh_addr_root "$env_opts /root/__undercloud-install-1-as-root.sh"

scp $SSH_OPTS "$my_dir/overcloud-install.sh" ${ssh_addr_stack}:/home/stack/overcloud-install.sh
scp $SSH_OPTS "$my_dir/save_logs.sh" ${ssh_addr_stack}:/home/stack/save_logs.sh

echo "SSH into undercloud: ssh -T $SSH_OPTS $ssh_addr"
