#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ssh_key_dir="/home/jenkins/.ssh"

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
IMAGES=${IMAGES:-"/home/jenkins/overcloud-images/images-${ENVIRONMENT_OS}-${ENVIRONMENT_OS_VERSION}-${OPENSTACK_VERSION}.tar"}
NETDEV=${NETDEV:-'eth1'}

# on kvm host do once: create stack user, create home directory, add him to libvirtd group
((env_addr=BASE_ADDR+NUM*10))
ip_addr="192.168.${env_addr}.2"
ssh_opts="-i $ssh_key_dir/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ssh_addr="root@${ip_addr}"

source "$my_dir/../common/virsh/functions"

# copy images for overcloud to it. (images can be build manually but it's too long - use previously built images)
if [ -f $IMAGES ] ; then
  scp $ssh_opts -B $IMAGES ${ssh_addr}:/tmp/images.tar
fi

for filename in "../common/virsh/functions" __undercloud-install-1-as-root.sh __undercloud-install-2-as-stack-user.sh ; do
  scp $ssh_opts -B "$my_dir/$filename" ${ssh_addr}:/root/
done

# Copy undercloud OTP token for FreeIPA
otp=''
if [[ "$FREE_IPA" == 'true' ]] ; then
  freeipaip="192.168.${env_addr}.4"
  otp=$(ssh -T $ssh_opts root@$freeipaip cat undercloud_otp)
  scp $ssh_opts "$my_dir/tht_ipa.diff" ${ssh_addr}:/home/stack/
fi

env_opts="NUM=$NUM NETDEV=$NETDEV OPENSTACK_VERSION=$OPENSTACK_VERSION"
env_opts+=" ENVIRONMENT_OS=$ENVIRONMENT_OS ENVIRONMENT_OS_VERSION=$ENVIRONMENT_OS_VERSION"
env_opts+=" TLS=$TLS DPDK=$DPDK TSN=$TSN SRIOV=$SRIOV"
env_opts+=" RHEL_CERT_TEST=$RHEL_CERT_TEST RHEL_ACCOUNT_FILE=$RHEL_ACCOUNT_FILE"
env_opts+=" CLEAN_ENV=$CLEAN_ENV"
env_opts+=" FREE_IPA=$FREE_IPA FREE_IPA_OTP=$otp CLOUD_DOMAIN_NAME=$CLOUD_DOMAIN_NAME"
ssh -T $ssh_opts $ssh_addr "$env_opts /root/__undercloud-install-1-as-root.sh"

#debug output
echo vbmc status
vbmc list

#Checking vbmc statuses
for vm in $(vbmc list -f value -c 'Domain name' -c Status | grep down | awk '{print $1}'); do
    vbmc start ${vm}
done    

scp $ssh_opts "$my_dir/overcloud-install.sh" ${ssh_addr}:/home/stack/overcloud-install.sh
scp $ssh_opts "$my_dir/overcloud-delete.sh" ${ssh_addr}:/home/stack/overcloud-delete.sh
scp $ssh_opts "$my_dir/save_logs.sh" ${ssh_addr}:/home/stack/save_logs.sh

echo "SSH into undercloud: ssh -T $ssh_opts $ssh_addr"
