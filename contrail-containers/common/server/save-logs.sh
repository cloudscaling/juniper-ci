#!/bin/bash -x

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/ssh-defs"

cat <<EOF | timeout -s 9 60s $SSH_CMD ${SSH_USER}@$master_ip
set -x
export PATH=\${PATH}:/usr/sbin
mkdir -p ~/logs/kube-info
if [[ command -v kubectl ]]; then
  kubectl get nodes -o wide > ~/logs/kube-info/nodes 2>&1 || true
  kubectl get pods -o wide --all-namespaces=true > ~/logs/kube-info/pods 2>&1 || true
  kubectl get all -o wide --all-namespaces=true > ~/logs/kube-info/apps 2>&1 || true
fi
for i in ~/my-contrail.yaml ~/test_app.yaml ; do
  cp \$i ~/logs/ || true
done
EOF

# save contrail logs
for dest in ${nodes_ips[@]} ; do
  # TODO: when repo be splitted to containers & build here will be containers repo only,
  # then build repo should be added to be copied below
  cat <<EOF | timeout -s 9 60s ssh -i $ssh_key_file $SSH_OPTS ${SSH_USER}@${dest}
mkdir -p ~/logs/k8s
for i in /var/log/contrail /var/log/containers /etc/cni ; do
  cp -r \$i ~/logs/k8s/ || true
done
EOF
done
