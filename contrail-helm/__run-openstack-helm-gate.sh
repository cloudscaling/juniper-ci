#!/bin/bash -ex

if [[ "$USE_SWAP" == "true" ]] ; then
  sudo mkswap /dev/xvdf
  sudo swapon /dev/xvdf
  swapon -s
fi

echo "INFO: Preparing instances"

if [[ -x $(command -v apt-get 2>/dev/null) ]]; then
  HOST_OS='ubuntu'
elif [[ -x $(command -v yum 2>/dev/null) ]]; then
  HOST_OS='centos'
else
  echo "ERROR: Unable to find apt-get or yum"
  exit 1
fi

if [ "x$HOST_OS" == "xubuntu" ]; then
  sudo apt-get -y update && sudo apt-get -y upgrade
  sudo apt-get install -y --no-install-recommends mc git wget ntp docker.io jq
elif [ "x$HOST_OS" == "xcentos" ]; then
  sudo yum install -y epel-release
  sudo cp ./ceph.repo /etc/yum.repos.d/ceph.repo
  sudo yum install -y mc git wget ntp docker-latest jq

  sudo cp -f /usr/lib/systemd/system/docker-latest.service /etc/systemd/system/docker.service
  sudo sed -i "s|/var/lib/docker-latest|/var/lib/docker|g" /etc/systemd/system/docker.service
  sudo sed -i 's/^OPTIONS/#OPTIONS/g' /etc/sysconfig/docker-latest
  sudo sed -i "s|^MountFlags=slave|MountFlags=share|g" /etc/systemd/system/docker.service
  sudo sed -i "/--seccomp-profile/,+1 d" /etc/systemd/system/docker.service
  echo "DOCKER_STORAGE_OPTIONS=--storage-driver=overlay" | sudo tee /etc/sysconfig/docker-latest-storage
  sudo setenforce 0 || true
  sudo systemctl daemon-reload
  sudo systemctl restart docker
fi


./containers-build-${HOST_OS}.sh


#sudo docker pull docker.io/opencontrail/contrail-controller-ubuntu16.04:4.0.2.0
#sudo docker pull docker.io/opencontrail/contrail-analyticsdb-ubuntu16.04:4.0.2.0
#sudo docker pull docker.io/opencontrail/contrail-analytics-ubuntu16.04:4.0.2.0
sudo docker pull docker.io/opencontrail/contrail-kube-manager-ubuntu16.04:4.0.2.0
sudo docker pull docker.io/opencontrail/contrail-agent-ubuntu16.04:4.0.2.0
sudo docker pull docker.io/opencontrail/contrail-kubernetes-agent-ubuntu16.04:4.0.2.0


git clone https://github.com/cloudscaling/openstack-helm
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
