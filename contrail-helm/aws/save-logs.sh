#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/ssh-defs"

$SSH "tar -cvf logs.tar /home/ubuntu/openstack-helm/logs ; gzip logs.tar"
$SCP $SSH_DEST:logs.tar.gz "$WORKSPACE/logs/logs.tar.gz"
pushd "$WORKSPACE/logs"
tar -xvf logs.tar.gz
rm logs.tar.gz
popd ..
