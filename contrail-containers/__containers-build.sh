#!/bin/bash -e

if [[ -x $(command -v apt-get 2>/dev/null) ]]; then
  echo "INFO: Preparing Ubuntu host to build containers  $(date)"
  sudo apt-get -y update
  sudo DEBIAN_FRONTEND=noninteractive apt-get -fqy -o Dpkg::Options::=\"--force-confold\" upgrade
  sudo apt-get install -y --no-install-recommends mc git wget ntp
elif [[ -x $(command -v yum 2>/dev/null) ]]; then
  echo "INFO: Preparing CentOS host to build containers  $(date)"
  # ip is located in /usr/sbin that is not in path...
  export PATH=${PATH}:/usr/sbin
  sudo yum install -y epel-release
  sudo yum install -y mc git wget ntp iptables iproute
  sudo systemctl enable ntpd.service
  sudo systemctl start ntpd.service
else
  echo "ERROR: Unable to find apt-get or yum"
  exit 1
fi

echo "INFO: Run setup-for-build  $(date)"

git clone $DOCKER_CONTRAIL_URL
cd contrail-container-builder/containers
./setup-for-build.sh

echo "INFO: Run build  $(date)"

sudo -E ./build.sh || /bin/true
sudo docker images | grep "$CONTRAIL_VERSION"

echo "INFO: Build finished  $(date)"
