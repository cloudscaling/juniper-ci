#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/ssh-defs"

mkdir -p ~/logs/kube-info
kubectl get nodes -o wide > ~/logs/kube-info/nodes 2>&1 || true
kubectl get pods -o wide --all-namespaces=true > ~/logs/kube-info/pods 2>&1 || true
kubectl get all -o wide --all-namespaces=true > ~/logs/kube-info/apps 2>&1 || true

data="/var/log/contrail"
data+=" /var/log/containers"
data+=" /etc/cni"
data+=" ~/my-contrail-micro.yaml"
data+=" ~/test_app.yaml"
mkdir -p ~/logs/k8s
for i in $folders ; do
  cp -r $i ~/logs/k8s || true
done
