#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ssh_key_dir="/home/jenkins"

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

BASE_ADDR=${BASE_ADDR:-172}
IMAGES=${IMAGES:-"/home/stack/images-${ENVIRONMENT_OS}-${OPENSTACK_VERSION}.tar"}
NETDEV=${NETDEV:-'eth1'}

# on kvm host do once: create stack user, create home directory, add him to libvirtd group
((env_addr=BASE_ADDR+NUM*10))
ip_addr="192.168.${env_addr}.2"
ssh_opts="-i $ssh_key_dir/kp-$NUM -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ssh_addr="root@${ip_addr}"

source "$my_dir/functions"

# copy images for overcloud to it. (images can be build manually but it's too long - use previously built images)
if [ -f $IMAGES ] ; then
  # TODO: to avoid duplication for undercloud and overcloud
  # register rhel overcloud image
  if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
    tmp_dir=$(mktemp -d)
    if [[ -z "$tmp_dir" ]] ; then
      echo "ERROR: failed to get tmp dir"
      exit 1
    fi
    pushd $tmp_dir
    tar -xf $IMAGES
    rhel_register_system_and_enable_repos "images/overcloud-full.qcow2"
    chown -R stack:stack images
    tar -cf images.tar images
    chown stack:stack images.tar
    scp $ssh_opts -B images.tar ${ssh_addr}:/tmp/images.tar
    popd
    rm -rf $tmp_dir
  else
    scp $ssh_opts -B $IMAGES ${ssh_addr}:/tmp/images.tar
  fi
else
  if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
    echo "ERROR: image building is not supported for rhel env"
    exit 1
  fi
fi

for fff in __undercloud-install-1-as-root.sh __undercloud-install-2-as-stack-user.sh ; do
  scp $ssh_opts -B "$my_dir/$fff" ${ssh_addr}:/root/$fff
done
env_opts="NUM=$NUM NETDEV=$NETDEV OPENSTACK_VERSION=$OPENSTACK_VERSION ENVIRONMENT_OS=$ENVIRONMENT_OS DPDK=$DPDK RHEL_CERT_TEST=$RHEL_CERT_TEST RHEL_ACCOUNT_FILE=$RHEL_ACCOUNT_FILE"
ssh -T $ssh_opts $ssh_addr "$env_opts /root/__undercloud-install-1-as-root.sh"

scp $ssh_opts "$my_dir/overcloud-install.sh" ${ssh_addr}:/home/stack/overcloud-install.sh
scp $ssh_opts "$my_dir/save_logs.sh" ${ssh_addr}:/home/stack/save_logs.sh

echo "SSH into undercloud: ssh -T $ssh_opts $ssh_addr"
