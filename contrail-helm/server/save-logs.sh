#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/ssh-defs"

folders="/var/log/contrail"
folders+=" /var/log/containers"
folders+=" /etc/cni"
folders+=" ~/my-contrail-micro.yaml"
folders+=" ~/test_app.yaml"
folders+=" ~/kube-info"

mkdir ~/kube-info
kubectl get nodes -o wide > ~/kube-info/nodes 2>&1
kubectl get pods -o wide --all-namespaces=true > ~/kube-info/pods 2>&1
kubectl get all -o wide --all-namespaces=true > ~/kube-info/apps 2>&1

if $SSH "tar -czvf --ignore-failed-read logs.tar.gz $folders" ; then
  $SCP $SSH_DEST:logs.tar.gz "$WORKSPACE/logs/logs.tar.gz"
  pushd "$WORKSPACE/logs"
  tar -xvf logs.tar.gz
  rm logs.tar.gz
  popd
fi
