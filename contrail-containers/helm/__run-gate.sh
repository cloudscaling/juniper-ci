#!/bin/bash -e

AAA_MODE=${AAA_MODE:-cloud-admin}
tag="$CONTRAIL_VERSION"

# tune some host settings
sudo sysctl -w vm.max_map_count=1048575

if [[ "$REGISTRY_INSECURE" == '1' ]] ; then
  sudo mkdir -p /etc/docker
  cat | sudo tee /etc/docker/daemon.json << EOF
{
    "insecure-registries": ["$CONTAINER_REGISTRY"]
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

extra_neutron_args=''
if [[ "$AAA_MODE" == 'rbac' ]]; then
  extra_neutron_args="--values ./tools/overrides/backends/opencontrail/neutron-rbac.yaml"
fi
export OSH_EXTRA_HELM_ARGS_NEUTRON="$extra_neutron_args --set images.tags.opencontrail_neutron_init=$CONTAINER_REGISTRY/contrail-openstack-neutron-init:$tag"
echo "INFO: extra neutron args: $OSH_EXTRA_HELM_ARGS_NEUTRON"
extra_nova_args=''
if [[ "$OPENSTACK_VERSION" == 'ocata' ]]; then
  extra_nova_args="--set compute_patch=true"
fi
export OSH_EXTRA_HELM_ARGS_NOVA="$extra_nova_args --set images.tags.opencontrail_compute_init=$CONTAINER_REGISTRY/contrail-openstack-compute-init:$tag"
echo "INFO: extra nova args: $OSH_EXTRA_HELM_ARGS_NOVA"
export OSH_EXTRA_HELM_ARGS_HEAT="--set images.tags.opencontrail_heat_init=$CONTAINER_REGISTRY/contrail-openstack-heat-init:$tag"
echo "INFO: extra heat args: $OSH_EXTRA_HELM_ARGS_HEAT"

# Download openstack-helm code
git clone https://github.com/Juniper/openstack-helm.git
pushd openstack-helm
#git fetch https://review.opencontrail.org/Juniper/openstack-helm refs/changes/52/40952/4 && git checkout FETCH_HEAD
#git pull --rebase origin master
popd
# Download openstack-helm-infra code
git clone https://github.com/Juniper/openstack-helm-infra.git
# Download contrail-helm-deployer code
git clone https://github.com/Juniper/contrail-helm-deployer.git
pushd contrail-helm-deployer
#git fetch https://review.opencontrail.org/Juniper/contrail-helm-deployer refs/changes/66/41266/4 && git checkout FETCH_HEAD
#git pull --rebase origin master
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
./tools/deployment/developer/nfs/161-compute-kit-opencontrail.sh

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
  images:
    tags:
      kafka: "$CONTAINER_REGISTRY/contrail-external-kafka:$tag"
      cassandra: "$CONTAINER_REGISTRY/contrail-external-cassandra:$tag"
      redis: "redis:4.0.2"
      zookeeper: "$CONTAINER_REGISTRY/contrail-external-zookeeper:$tag"
      contrail_control: "$CONTAINER_REGISTRY/contrail-controller-control-control:$tag"
      control_dns: "$CONTAINER_REGISTRY/contrail-controller-control-dns:$tag"
      control_named: "$CONTAINER_REGISTRY/contrail-controller-control-named:$tag"
      config_api: "$CONTAINER_REGISTRY/contrail-controller-config-api:$tag"
      config_devicemgr: "$CONTAINER_REGISTRY/contrail-controller-config-devicemgr:$tag"
      config_schema_transformer: "$CONTAINER_REGISTRY/contrail-controller-config-schema:$tag"
      config_svcmonitor: "$CONTAINER_REGISTRY/contrail-controller-config-svcmonitor:$tag"
      webui_middleware: "$CONTAINER_REGISTRY/contrail-controller-webui-job:$tag"
      webui: "$CONTAINER_REGISTRY/contrail-controller-webui-web:$tag"
      analytics_api: "$CONTAINER_REGISTRY/contrail-analytics-api:$tag"
      contrail_collector: "$CONTAINER_REGISTRY/contrail-analytics-collector:$tag"
      analytics_alarm_gen: "$CONTAINER_REGISTRY/contrail-analytics-alarm-gen:$tag"
      analytics_query_engine: "$CONTAINER_REGISTRY/contrail-analytics-query-engine:$tag"
      analytics_snmp_collector: "$CONTAINER_REGISTRY/contrail-analytics-snmp-collector:$tag"
      contrail_topology: "$CONTAINER_REGISTRY/contrail-analytics-topology:$tag"
      build_driver_init: "$CONTAINER_REGISTRY/contrail-vrouter-kernel-build-init:$tag"
      vrouter_agent: "$CONTAINER_REGISTRY/contrail-vrouter-agent:$tag"
      vrouter_init_kernel: "$CONTAINER_REGISTRY/contrail-vrouter-kernel-init:$tag"
      vrouter_dpdk: "$CONTAINER_REGISTRY/contrail-vrouter-agent-dpdk:$tag"
      vrouter_init_dpdk: "$CONTAINER_REGISTRY/contrail-vrouter-kernel-init-dpdk:$tag"
      dpdk_watchdog: "$CONTAINER_REGISTRY/contrail-vrouter-net-watchdog:$tag"
      nodemgr: "$CONTAINER_REGISTRY/contrail-nodemgr:$tag"
      contrail_status: "$CONTAINER_REGISTRY/contrail-status:$tag"
      node_init: "$CONTAINER_REGISTRY/contrail-node-init:$tag"
      dep_check: quay.io/stackanetes/kubernetes-entrypoint:v0.2.1
  contrail_env:
    CONTROLLER_NODES: ${CONTROL_NODE}
    LOG_LEVEL: SYS_DEBUG
    CLOUD_ORCHESTRATOR: openstack
    AAA_MODE: $AAA_MODE
    CONTROL_DATA_NET_LIST:
    VROUTER_GATEWAY:
EOF

helm install --name contrail ${CHD_PATH}/contrail --namespace=contrail --values=/tmp/contrail.yaml
${OSH_PATH}/tools/deployment/common/wait-for-pods.sh contrail

cd ${OSH_PATH}

# workaround steps. remove later.
make build-helm-toolkit
make build-heat

./tools/deployment/developer/nfs/091-heat-opencontrail.sh

# lets wait for services
sleep 60
sudo contrail-status

./tools/deployment/developer/nfs/901-use-it-opencontrail.sh

exit $err
