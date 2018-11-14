#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

mkdir -p $my_dir/logs
source "$my_dir/cloudrc"

AAA_MODE=${AAA_MODE:-cloud-admin}
tag="$CONTRAIL_VERSION"

# tune some host settings
sudo sysctl -w vm.max_map_count=1048575
mkdir -p /var/crashes

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
export OSH_INFRA_PATH=${BASE_DIR}/openstack-helm-infra
export CHD_PATH=${BASE_DIR}/contrail-helm-deployer

cat <<EOF > $OSH_INFRA_PATH/tools/gate/devel/multinode-vars.yaml
version:
  kubernetes: v1.8.3
  helm: v2.7.2
  cni: v0.6.0
kubernetes:
  network:
    default_device: ens3
  cluster:
    cni: calico
    pod_subnet: 192.168.0.0/16
    domain: cluster.local
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

sudo apt-get update
sudo apt-get install --no-install-recommends -y ca-certificates make jq nmap curl uuid-runtime linux-headers-$(uname -r) ipcalc

cat > $OSH_INFRA_PATH/tools/gate/devel/multinode-inventory.yaml <<EOF
all:
  children:
EOF

key_file="$my_dir/kp"
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
EOF
if [ -f $key_file ]; then
cat >> $OSH_INFRA_PATH/tools/gate/devel/multinode-inventory.yaml <<EOF
          ansible_ssh_private_key_file: $key_file
EOF
fi

set -x
cd ${OSH_INFRA_PATH}
make dev-deploy setup-host multinode
make dev-deploy k8s multinode

nslookup kubernetes.default.svc.cluster.local || /bin/true
kubectl get nodes -o wide

# names are assigned by kubernetes. use the same algorithm to generate name.
for ip in $nodes_cont_ips ; do
  name="node-$(echo $ip | tr '.' '-').local"
  kubectl label node $name --overwrite openstack-compute-node=disable
  kubectl label node $name opencontrail.org/controller=enabled
done
for ip in $nodes_comp_ips ; do
  name="node-$(echo $ip | tr '.' '-').local"
  kubectl label node $name --overwrite openstack-control-plane=disable
  if [[ "$AGENT_MODE" == "dpdk" ]]; then
    kubectl label node $name opencontrail.org/vrouter-dpdk=enabled
  else
    kubectl label node $name opencontrail.org/vrouter-kernel=enabled
  fi
done

cd $CHD_PATH
make
kubectl replace -f ${CHD_PATH}/rbac/cluster-admin.yaml

controller_nodes=`echo $nodes_cont_ips | tr ' ' ','`
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
    LOG_LEVEL: SYS_DEBUG
    CLOUD_ORCHESTRATOR: openstack
    AAA_MODE: $AAA_MODE
    SSL_ENABLE: $SSL_ENABLE
    JVM_EXTRA_OPTS: "-Xms1g -Xmx2g"
    BGP_PORT: "1179"
    CONFIG_DATABASE_NODEMGR__DEFAULTS__minimum_diskGB: "2"
    DATABASE_NODEMGR__DEFAULTS__minimum_diskGB: "2"
    IPFABRIC_SERVICE_HOST: ${METADATA_IP}
    METADATA_PROXY_SECRET: ${METADATA_PROXY_SECRET}
    VROUTER_ENCRYPTION: FALSE
endpoints:
  keystone:
    auth:
      username: admin
      password: password
      project_name: admin
      user_domain_name: admin_domain
      project_domain_name: admin_domain
      region_name: RegionOne
    hosts:
      default: ${AUTH_IP}
    path:
      default: /v3
    port:
      admin:
        default: 35357
      api:
        default: 5000
    scheme:
      default: http
    host_fqdn_override:
      default: ${AUTH_IP}
    namespace: null
EOF

helm install --name contrail-thirdparty ${CHD_PATH}/contrail-thirdparty --namespace=contrail --values=/tmp/contrail.yaml
helm install --name contrail-analytics ${CHD_PATH}/contrail-analytics --namespace=contrail --values=/tmp/contrail.yaml
helm install --name contrail-controller ${CHD_PATH}/contrail-controller --namespace=contrail --values=/tmp/contrail.yaml

echo "INFO: wait for pods. $(date)"
rm -f wait-for-pods.sh
wget -nv https://raw.githubusercontent.com/Juniper/openstack-helm/master/tools/deployment/common/wait-for-pods.sh
chmod a+x wait-for-pods.sh
./wait-for-pods.sh contrail
echo "INFO: pods.ready $(date)"

# lets wait for services
sleep 20
sudo contrail-status

exit $err
