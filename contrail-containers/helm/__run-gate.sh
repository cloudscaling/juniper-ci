#!/bin/bash -ex

AAA_MODE=${AAA_MODE:-cloud-admin}

# tune some host settings
sudo sysctl -w vm.max_map_count=1048575

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
if [ "x$HOST_OS" == "xcentos" ]; then
  # ip is located in /usr/sbin that is not in path...
  export PATH=${PATH}:/usr/sbin
  sudo cp ./ceph.repo /etc/yum.repos.d/ceph.repo
fi

extra_args=''
if [[ "$AAA_MODE" == 'rbac' ]]; then
  extra_args="--values ./tools/overrides/backends/opencontrail/neutron-rbac.yaml"
fi

# Download openstack-helm code
git clone https://github.com/Juniper/openstack-helm.git
pushd openstack-helm
git fetch https://review.opencontrail.org/Juniper/openstack-helm refs/changes/81/40881/1 && git checkout FETCH_HEAD
git pull --rebase origin master
popd
# Download openstack-helm-infra code
git clone https://github.com/Juniper/openstack-helm-infra.git
# Download contrail-helm-deployer code
git clone https://github.com/Juniper/contrail-helm-deployer.git
pushd contrail-helm-deployer
git fetch https://review.opencontrail.org/Juniper/contrail-helm-deployer refs/changes/75/40875/3 && git checkout FETCH_HEAD
git pull --rebase origin master
popd

export BASE_DIR=${WORKSPACE:-$(pwd)}
export OSH_PATH=${BASE_DIR}/openstack-helm
export OSH_INFRA_PATH=${BASE_DIR}/openstack-helm-infra
export CHD_PATH=${BASE_DIR}/contrail-helm-deployer

cd ${OSH_PATH}
./tools/deployment/developer/common/001-install-packages-opencontrail.sh
./tools/deployment/developer/common/010-deploy-k8s.sh

./tools/deployment/developer/common/020-setup-client.sh

./tools/deployment/developer/nfs/030-ingress.sh
./tools/deployment/developer/nfs/040-nfs-provisioner.sh
./tools/deployment/developer/nfs/050-mariadb.sh
./tools/deployment/developer/nfs/060-rabbitmq.sh
./tools/deployment/developer/nfs/070-memcached.sh
./tools/deployment/developer/nfs/080-keystone.sh
./tools/deployment/developer/nfs/100-horizon.sh
./tools/deployment/developer/nfs/120-glance.sh
./tools/deployment/developer/nfs/151-libvirt-opencontrail.sh
export OSH_EXTRA_HELM_ARGS="$extra_args"
./tools/deployment/developer/nfs/161-compute-kit-opencontrail.sh
unset OSH_EXTRA_HELM_ARGS

cd $CHD_PATH
make

# Set the IP of your CONTROL_NODES (specify your control data ip, if you have one)
export CONTROL_NODE=$(hostname -i)
# set the control data network cidr list separated by comma and set the respective gateway
#export CONTROL_DATA_NET_LIST=10.87.65.128/25
#export VROUTER_GATEWAY=10.87.65.129

kubectl label node opencontrail.org/controller=enabled --all
kubectl label node opencontrail.org/vrouter-kernel=enabled --all

kubectl replace -f ${CHD_PATH}/rbac/cluster-admin.yaml

tee /tmp/contrail.yaml << EOF
global:
  contrail_env:
    CONTROLLER_NODES: ${CONTROL_NODE}
    LOG_LEVEL: SYS_DEBUG
    CLOUD_ORCHESTRATOR: openstack
    AAA_MODE: $AAA_MODE
EOF
#CONTROL_DATA_NET_LIST: ${CONTROL_DATA_NET_LIST}
#VROUTER_GATEWAY: ${VROUTER_GATEWAY}

helm install --name contrail ${CHD_PATH}/contrail --namespace=contrail --values=/tmp/contrail.yaml

cd ${OSH_PATH}

# workaround steps. remove later.
make build-helm-toolkit
make build-heat

./tools/deployment/developer/nfs/091-heat-opencontrail.sh

# lets wait for services
sleep 60

./tools/deployment/developer/nfs/901-use-it-opencontrail.sh

mv logs ../

exit $err
