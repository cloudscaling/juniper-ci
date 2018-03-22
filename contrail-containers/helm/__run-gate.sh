#!/bin/bash -e

AAA_MODE=${AAA_MODE:-cloud-admin}
tag='ocata-master-34'

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

extra_neutron_args=''
if [[ "$AAA_MODE" == 'rbac' ]]; then
  extra_neutron_args="--values ./tools/overrides/backends/opencontrail/neutron-rbac.yaml"
fi
export OSH_EXTRA_HELM_ARGS_NEUTRON="$extra_neutron_args --set images.tags.opencontrail_neutron_init=docker.io/opencontrailnightly/contrail-openstack-neutron-init:$tag"
echo "INFO: extra neutron args: $OSH_EXTRA_HELM_ARGS_NEUTRON"
extra_nova_args=''
if [[ "$OPENSTACK_VERSION" == 'ocata' ]]; then
  extra_nova_args="--set compute_patch=true"
fi
export OSH_EXTRA_HELM_ARGS_NOVA="$extra_nova_args --set images.tags.opencontrail_compute_init=docker.io/opencontrailnightly/contrail-openstack-compute-init:$tag"
echo "INFO: extra nova args: $OSH_EXTRA_HELM_ARGS_NOVA"
export OSH_EXTRA_HELM_ARGS_HEAT="--set images.tags.opencontrail_heat_init=docker.io/opencontrailnightly/contrail-openstack-heat-init:$tag"
echo "INFO: extra heat args: $OSH_EXTRA_HELM_ARGS_HEAT"

# Download openstack-helm code
git clone https://github.com/Juniper/openstack-helm.git
pushd openstack-helm
git fetch https://review.opencontrail.org/Juniper/openstack-helm refs/changes/52/40952/4 && git checkout FETCH_HEAD
git pull --rebase origin master
popd
# Download openstack-helm-infra code
git clone https://github.com/Juniper/openstack-helm-infra.git
# Download contrail-helm-deployer code
git clone https://github.com/Juniper/contrail-helm-deployer.git
pushd contrail-helm-deployer
git fetch https://review.opencontrail.org/Juniper/contrail-helm-deployer refs/changes/37/40937/1 && git checkout FETCH_HEAD
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
      kafka: "docker.io/opencontrailnightly/contrail-external-kafka:$tag"
      cassandra: "docker.io/opencontrailnightly/contrail-external-cassandra:$tag"
      redis: "redis:4.0.2"
      zookeeper: "docker.io/opencontrailnightly/contrail-external-zookeeper:$tag"
      contrail_control: "docker.io/opencontrailnightly/contrail-controller-control-control:$tag"
      control_dns: "docker.io/opencontrailnightly/contrail-controller-control-dns:$tag"
      control_named: "docker.io/opencontrailnightly/contrail-controller-control-named:$tag"
      config_api: "docker.io/opencontrailnightly/contrail-controller-config-api:$tag"
      config_devicemgr: "docker.io/opencontrailnightly/contrail-controller-config-devicemgr:$tag"
      config_schema_transformer: "docker.io/opencontrailnightly/contrail-controller-config-schema:$tag"
      config_svcmonitor: "docker.io/opencontrailnightly/contrail-controller-config-svcmonitor:$tag"
      webui_middleware: "docker.io/opencontrailnightly/contrail-controller-webui-job:$tag"
      webui: "docker.io/opencontrailnightly/contrail-controller-webui-web:$tag"
      analytics_api: "docker.io/opencontrailnightly/contrail-analytics-api:$tag"
      contrail_collector: "docker.io/opencontrailnightly/contrail-analytics-collector:$tag"
      analytics_alarm_gen: "docker.io/opencontrailnightly/contrail-analytics-alarm-gen:$tag"
      analytics_query_engine: "docker.io/opencontrailnightly/contrail-analytics-query-engine:$tag"
      analytics_snmp_collector: "docker.io/opencontrailnightly/contrail-analytics-snmp-collector:$tag"
      contrail_topology: "docker.io/opencontrailnightly/contrail-analytics-topology:$tag"
      build_driver_init: "docker.io/opencontrailnightly/contrail-vrouter-kernel-build-init:$tag"
      vrouter_agent: "docker.io/opencontrailnightly/contrail-vrouter-agent:$tag"
      vrouter_init_kernel: "docker.io/opencontrailnightly/contrail-vrouter-kernel-init:$tag"
      vrouter_dpdk: "docker.io/opencontrailnightly/contrail-vrouter-agent-dpdk:$tag"
      vrouter_init_dpdk: "docker.io/opencontrailnightly/contrail-vrouter-kernel-init-dpdk:$tag"
      dpdk_watchdog: "docker.io/opencontrailnightly/contrail-vrouter-net-watchdog:$tag"
      nodemgr: "docker.io/opencontrailnightly/contrail-nodemgr:$tag"
      dep_check: quay.io/stackanetes/kubernetes-entrypoint:v0.2.1
  contrail_env:
    CONTROLLER_NODES: ${CONTROL_NODE}
    LOG_LEVEL: SYS_DEBUG
    CLOUD_ORCHESTRATOR: openstack
    AAA_MODE: $AAA_MODE
    CONTROL_DATA_NET_LIST:
    VROUTER_GATEWAY:
    BGP_PORT: "1179"
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

./tools/deployment/developer/nfs/901-use-it-opencontrail.sh

exit $err
