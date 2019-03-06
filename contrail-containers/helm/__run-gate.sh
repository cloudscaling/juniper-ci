#!/bin/bash -eE

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

mkdir -p $my_dir/logs
source "$my_dir/cloudrc"

AAA_MODE=${AAA_MODE:-rbac}
tag="$CONTRAIL_VERSION"

# tune some host settings
sudo sysctl -w vm.max_map_count=1048575

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
fi

export BASE_DIR=/opt
mkdir -p $BASE_DIR
export OSH_PATH=${BASE_DIR}/openstack-helm
export OSH_INFRA_PATH=${BASE_DIR}/openstack-helm-infra
export CHD_PATH=${BASE_DIR}/contrail-helm-deployer

cat <<EOF > $OSH_INFRA_PATH/tools/gate/devel/multinode-vars.yaml
version:
  kubernetes: v1.9.3
  helm: v2.7.2
  cni: v0.6.0
kubernetes:
  network:
    default_device: ens3
  cluster:
    cni: calico
    pod_subnet: 192.168.0.0/16
    domain: ${DOMAIN}
EOF
if [[ "$REGISTRY_INSECURE" == '1' ]] ; then
  cat <<EOF >> $OSH_INFRA_PATH/tools/gate/devel/multinode-vars.yaml
docker:
  insecure_registries:
    - "$CONTAINER_REGISTRY"
EOF
fi

if [[ "${SSL_ENABLE,,}" == 'true' ]] ; then
  cat <<EOF >> $OSH_INFRA_PATH/tools/gate/devel/multinode-vars.yaml
tls_config:
  generate: true
  organization: Contrail
  cert_file: "/etc/contrail/ssl/certs/server.pem"
  key_file: "/etc/contrail/ssl/private/server-privkey.pem"
  ca_file: "/etc/contrail/ssl/certs/ca-cert.pem"
EOF
fi


cd ${OSH_PATH}
./tools/deployment/developer/common/001-install-packages-opencontrail.sh

cat > $OSH_INFRA_PATH/tools/gate/devel/multinode-inventory.yaml <<EOF
all:
  children:
EOF

ips=($nodes_ips)
ip="${ips[0]}"
name=`echo node_$ip | tr '.' '_'`
cat >> $OSH_INFRA_PATH/tools/gate/devel/multinode-inventory.yaml <<EOF
    primary:
      hosts:
        $name:
          ansible_port: 22
          ansible_host: $ip
          ansible_user: $SSH_USER
          ansible_ssh_extra_args: -o StrictHostKeyChecking=no
          ansible_ssh_private_key_file: $HOME/.ssh/id_rsa
    nodes:
      hosts:
EOF
for ip in ${ips[@]:1} ; do
  name=`echo node_$ip | tr '.' '_'`
  cat >> $OSH_INFRA_PATH/tools/gate/devel/multinode-inventory.yaml <<EOF
        $name:
          ansible_port: 22
          ansible_host: $ip
          ansible_user: $SSH_USER
          ansible_ssh_extra_args: -o StrictHostKeyChecking=no
          ansible_ssh_private_key_file: $HOME/.ssh/id_rsa
EOF
done

set -x
cd ${OSH_INFRA_PATH}
make dev-deploy setup-host multinode
sudo make dev-deploy k8s multinode

nslookup kubernetes.default.svc.$DOMAIN || /bin/true
kubectl get nodes -o wide

# names are assigned by kubernetes. use the same algorithm to generate name.
for ip in $nodes_cont_ips ; do
  name="node-$(echo $ip | tr '.' '-').$DOMAIN"
  kubectl label node $name --overwrite openstack-compute-node=disable
  kubectl label node $name opencontrail.org/controller=enabled
done
for ip in $nodes_comp_ips ; do
  name="node-$(echo $ip | tr '.' '-').$DOMAIN"
  kubectl label node $name --overwrite openstack-control-plane=disable
  if [[ "$AGENT_MODE" == "dpdk" ]]; then
    kubectl label node $name opencontrail.org/vrouter-dpdk=enabled
  else
    kubectl label node $name opencontrail.org/vrouter-kernel=enabled
  fi
done

cd ${OSH_PATH}
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

./tools/deployment/multinode/010-setup-client.sh
./tools/deployment/multinode/021-ingress-opencontrail.sh
./tools/deployment/multinode/030-ceph.sh
./tools/deployment/multinode/040-ceph-ns-activate.sh
./tools/deployment/multinode/050-mariadb.sh
./tools/deployment/multinode/060-rabbitmq.sh
./tools/deployment/multinode/070-memcached.sh
./tools/deployment/multinode/080-keystone.sh
./tools/deployment/multinode/090-ceph-radosgateway.sh
./tools/deployment/multinode/100-glance.sh
./tools/deployment/multinode/110-cinder.sh
./tools/deployment/multinode/131-libvirt-opencontrail.sh

cd $CHD_PATH
make
#kubectl replace -f ${CHD_PATH}/rbac/cluster-admin.yaml

controller_nodes=`echo $nodes_cont_ips | tr ' ' ','`
control_nodes=`echo $nodes_cont_ips_1 | tr ' ' ','`
tee /tmp/contrail.yaml << EOF
global:
  images:
    tags:
      kafka: "$CONTAINER_REGISTRY/contrail-external-kafka:$tag"
      cassandra: "$CONTAINER_REGISTRY/contrail-external-cassandra:$tag"
      redis: "$CONTAINER_REGISTRY/contrail-external-redis:$tag"
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
      nodemgr: "$CONTAINER_REGISTRY/contrail-nodemgr:$tag"
      contrail_status: "$CONTAINER_REGISTRY/contrail-status:$tag"
      node_init: "$CONTAINER_REGISTRY/contrail-node-init:$tag"
      dep_check: quay.io/stackanetes/kubernetes-entrypoint:v0.2.1
  contrail_env:
    CONTROLLER_NODES: $controller_nodes
    CONTROL_NODES: $control_nodes
    LOG_LEVEL: SYS_DEBUG
    CLOUD_ORCHESTRATOR: openstack
    AAA_MODE: $AAA_MODE
    SSL_ENABLE: $SSL_ENABLE
    JVM_EXTRA_OPTS: "-Xms1g -Xmx2g"
    BGP_PORT: "1179"
    CONFIG_DATABASE_NODEMGR__DEFAULTS__minimum_diskGB: "2"
    DATABASE_NODEMGR__DEFAULTS__minimum_diskGB: "2"
    VROUTER_GATEWAY: $nodes_gw_1
    VROUTER_ENCRYPTION: FALSE
    ANALYTICS_ALARM_ENABLE: TRUE
    ANALYTICS_SNMP_ENABLE: TRUE
    ANALYTICSDB_ENABLE: TRUE
manifests:
  configmap_vrouter_dpdk: true
  daemonset_dpdk: true
EOF

helm install --name contrail-thirdparty ${CHD_PATH}/contrail-thirdparty --namespace=contrail --values=/tmp/contrail.yaml
helm install --name contrail-analytics ${CHD_PATH}/contrail-analytics --namespace=contrail --values=/tmp/contrail.yaml
helm install --name contrail-controller ${CHD_PATH}/contrail-controller --namespace=contrail --values=/tmp/contrail.yaml
helm install --name contrail-vrouter ${CHD_PATH}/contrail-vrouter --namespace=contrail --values=/tmp/contrail.yaml
${OSH_PATH}/tools/deployment/common/wait-for-pods.sh contrail

# let's wait for services
sleep 60
sudo contrail-status

cd ${OSH_PATH}
./tools/deployment/multinode/141-compute-kit-opencontrail.sh || /bin/true

# workaround steps. remove later.
make build-helm-toolkit
make build-heat

./tools/deployment/developer/nfs/091-heat-opencontrail.sh

sudo apt-get install -fy virtualenv &>> $my_dir/logs/apt.log
export OS_CLOUD=openstack_helm

res=0
cd $my_dir
source $my_dir/check-functions
virtualenv .venv
source .venv/bin/activate
if ! command -v pip ; then
  # TODO: move these checks with pip into container
  echo "ERROR: please install python-pip manually to the deployer node"
  res=1
else
  pip install python-openstackclient &>> $my_dir/logs/pip.log || /bin/true
  prepare_openstack && check_simple_instance
fi
deactivate

exit $res
