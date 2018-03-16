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
  args=$(mktemp)
  cat <<EOF >$args
conf:
  paste:
    composite:neutronapi_v2_0:
      keystone: user_token cors http_proxy_to_wsgi request_id catch_errors authtoken keystonecontext extensions neutronapiapp_v2_0
    filter:user_token:
      paste.filter_factory: neutron_plugin_contrail.plugins.opencontrail.neutron_middleware:token_factory
EOF
  extra_args="--values $args"
fi

# Download openstack-helm code
git clone https://github.com/Juniper/openstack-helm.git
pushd openstack-helm
#git fetch https://review.opencontrail.org/Juniper/openstack-helm refs/changes/38/40638/2 && git checkout FETCH_HEAD
popd
# Download openstack-helm-infra code
git clone https://github.com/Juniper/openstack-helm-infra.git
# Download contrail-helm-deployer code
git clone https://github.com/Juniper/contrail-helm-deployer.git
pushd contrail-helm-deployer
git fetch https://review.opencontrail.org/Juniper/contrail-helm-deployer refs/changes/88/40688/1 && git checkout FETCH_HEAD
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

helm install --name contrail-thirdparty ${CHD_PATH}/contrail-thirdparty \
  --namespace=contrail --set contrail_env.CONTROLLER_NODES=$CONTROL_NODE \
  --set contrail_env.AAA_MODE=$AAA_MODE

helm install --name contrail-controller ${CHD_PATH}/contrail-controller \
  --namespace=contrail --set contrail_env.CONTROLLER_NODES=$CONTROL_NODE \
  --set contrail_env.CONTROL_NODES=${CONTROL_NODES} \
  --set contrail_env.AAA_MODE=$AAA_MODE

helm install --name contrail-analytics ${CHD_PATH}/contrail-analytics \
  --namespace=contrail --set contrail_env.CONTROLLER_NODES=$CONTROL_NODE \
  --set contrail_env.AAA_MODE=$AAA_MODE

# Edit contrail-vrouter/values.yaml and make sure that images.tags.vrouter_kernel_init is right. Image tag name will be different depending upon your linux. Also set the conf.host_os to ubuntu or centos depending on your system

helm install --name contrail-vrouter ${CHD_PATH}/contrail-vrouter \
  --namespace=contrail --set contrail_env.vrouter_common.CONTROLLER_NODES=${CONTROL_NODE} \
  --set contrail_env.vrouter_common.CONTROL_NODES=${CONTROL_NODE} \
  --set contrail_env.AAA_MODE=$AAA_MODE
#  --set contrail_env.vrouter_common.CONTROL_DATA_NET_LIST=${CONTROL_DATA_NET_LIST} \
#  --set contrail_env.vrouter_common.VROUTER_GATEWAY=${VROUTER_GATEWAY}

cd ${OSH_PATH}

# workaround steps. remove later.
make build-helm-toolkit
make build-heat

./tools/deployment/developer/nfs/091-heat-opencontrail.sh

./tools/deployment/developer/nfs/901-use-it-opencontrail.sh

mv logs ../

exit $err
