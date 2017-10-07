#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ENV_FILE="cloudrc"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30"

source $ENV_FILE
SSH_DEST="ubuntu@$public_ip"
SSH="ssh -i kp $SSH_OPTS $SSH_DEST"
SCP="scp -i kp $SSH_OPTS"

$SCP "$my_dir/__save_logs.sh" $SSH_DEST:__save_logs.sh
$SSH "__save_logs.sh"

$SSH "tar -cvf logs.tar /opt/stack/logs /opt/stack/tempest/tempest.log /opt/stack/tempest/etc /etc/nova /etc/cinder /etc/keystone /etc/ec2api /etc/gceapi ; gzip logs.tar"
mkdir -p logs
$SCP $SSH_DEST:logs.tar.gz logs/logs.tar.gz
cd logs
tar -xvf logs.tar.gz
cd ..


