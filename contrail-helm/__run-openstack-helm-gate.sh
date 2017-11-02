#!/bin/bash -ex

if [[ "$USE_SWAP" == "true" ]] ; then
  sudo mkswap /dev/xvdf
  sudo swapon /dev/xvdf
  swapon -s
fi

echo "INFO: Preparing instances"

if [[ -x $(command -v apt-get 2>/dev/null) ]]; then
  sudo apt-get -y update && sudo apt-get -y upgrade
  sudo apt-get install -y --no-install-recommends mc git wget ntp docker.io jq
elif [[ -x $(command -v yum 2>/dev/null) ]]; then
  sudo yum install -y epel-release
  sudo cp ./ceph.repo /etc/yum.repos.d/ceph.repo
  sudo yum install -y mc git wget ntp
else
  echo "ERROR: Unable to find apt-get or yum"
  exit 1
fi

sudo docker pull docker.io/opencontrail/contrail-controller-ubuntu16.04:4.0.2.0
sudo docker pull docker.io/opencontrail/contrail-analyticsdb-ubuntu16.04:4.0.2.0
sudo docker pull docker.io/opencontrail/contrail-analytics-ubuntu16.04:4.0.2.0
sudo docker pull docker.io/opencontrail/contrail-kube-manager-ubuntu16.04:4.0.2.0
sudo docker pull docker.io/opencontrail/contrail-agent-ubuntu16.04:4.0.2.0
sudo docker pull docker.io/opencontrail/contrail-kubernetes-agent-ubuntu16.04:4.0.2.0

git clone https://github.com/openstack/openstack-helm
cd openstack-helm

# fetch latest
if [[ -n "$CHANGE_REF" ]] ; then
  echo "INFO: Checking out change ref $CHANGE_REF"
  git fetch https://git.openstack.org/openstack/openstack-helm "$CHANGE_REF" && git checkout FETCH_HEAD
fi

export INTEGRATION=aio
export INTEGRATION_TYPE=basic
export SDN_PLUGIN=opencontrail
#export GLANCE=pvc
#export PVC_BACKEND=ceph
./tools/gate/setup_gate.sh
