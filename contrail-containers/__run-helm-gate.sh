#!/bin/bash -ex

if [[ "$USE_SWAP" == "true" ]] ; then
  sudo mkswap /dev/xvdf
  sudo swapon /dev/xvdf
  swapon -s
fi

registry_ip=${1:-localhost}
if [[ "$registry_ip" != 'localhost' ]] ; then
  sudo mkdir -p /etc/docker
  cat | sudo tee /etc/docker/daemon.json << EOF
{
    "insecure-registries": ["$registry_ip:5000"]
}
EOF
fi

if [[ -x $(command -v apt-get 2>/dev/null) ]]; then
  HOST_OS='ubuntu'
elif [[ -x $(command -v yum 2>/dev/null) ]]; then
  HOST_OS='centos'
else
  echo "ERROR: Unable to find apt-get or yum"
  exit 1
fi

echo "INFO: Preparing instances"
if [ "x$HOST_OS" == "xubuntu" ]; then
  sudo apt-get -y update && sudo apt-get -y upgrade
  sudo apt-get install -y --no-install-recommends mc git wget ntp ntpdate
  sudo ntpdate pool.ntp.org
elif [ "x$HOST_OS" == "xcentos" ]; then
  # ip is located in /usr/sbin that is not in path...
  export PATH=${PATH}:/usr/sbin

  sudo yum install -y epel-release
  sudo cp ./ceph.repo /etc/yum.repos.d/ceph.repo
  sudo yum install -y mc git wget ntp

  sudo yum install ntpdate || /bin/true
  sudo ntpdate pool.ntp.org

  # TODO: remove this hack
  wget -nv http://$registry_ip/$CONTRAIL_VERSION/vrouter.ko
  chmod 755 vrouter.ko
  sudo insmod ./vrouter.ko
fi

git clone ${OPENSTACK_HELM_URL:-https://github.com/openstack/openstack-helm}
cd openstack-helm

# fetch latest
if [[ -n "$CHANGE_REF" ]] ; then
  echo "INFO: Checking out change ref $CHANGE_REF"
  git fetch https://git.openstack.org/openstack/openstack-helm "$CHANGE_REF" && git checkout FETCH_HEAD
fi

# TODO: define the IP in chart
iface=`ip -4 route list 0/0 | awk '{ print $5; exit }'`
local_ip=`ip addr | grep $iface | grep 'inet ' | awk '{print $2}' | cut -d '/' -f 1`

# TODO: change next to nodes definition in helm
for fn in `grep -r -l 10.0.2.15 *`; do sed "s/10.0.2.15/$local_ip/g" < "$fn" > result; rm "$fn"; mv result "$fn"; done
# TODO: change next to images definition in helm
for fn in `grep -r -l "localhost:5000" *`; do sed "s/localhost:5000/${registry_ip}:5000/g" < "$fn" > result; rm "$fn"; mv result "$fn"; done

export INTEGRATION=aio
export INTEGRATION_TYPE=basic
export SDN_PLUGIN=opencontrail
#export GLANCE=pvc
#export PVC_BACKEND=ceph
err=0
./tools/gate/setup_gate.sh || err=$?

mv logs ../

exit $err
