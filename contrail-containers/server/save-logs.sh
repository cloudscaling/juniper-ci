#!/bin/bash -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/ssh-defs"

cat <<EOF | $SSH
set -x
export PATH=\${PATH}:/usr/sbin
mkdir -p ~/logs/kube-info
kubectl get nodes -o wide > ~/logs/kube-info/nodes 2>&1 || true
kubectl get pods -o wide --all-namespaces=true > ~/logs/kube-info/pods 2>&1 || true
kubectl get all -o wide --all-namespaces=true > ~/logs/kube-info/apps 2>&1 || true
mkdir -p ~/logs/k8s
for i in /var/log/contrail /var/log/containers /etc/cni ~/my-contrail.yaml ~/test_app.yaml ; do
  cp -r \$i ~/logs/k8s/ || true
done
EOF

