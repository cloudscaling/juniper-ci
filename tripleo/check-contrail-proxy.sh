#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ssh_addr=$1
shift
ssh_opts=$@

cos_dir='/home/stack/check-openstack'
ssh -t $ssh_opts $ssh_addr "mkdir -p $cos_dir/tripleo"
scp $my_dir/check-openstack.sh $ssh_opts $ssh_addr:$cos_dir/tripleo/
scp -r $my_dir/../common $ssh_opts $ssh_addr:$cos_dir/
ssh -t $ssh_opts $ssh_addr "chown -R stack:stack $cos_dir"
ssh -t $ssh_opts $ssh_addr "sudo -u stack $cos_dir/tripleo/check-openstack.sh"
