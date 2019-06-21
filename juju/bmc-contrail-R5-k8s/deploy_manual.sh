#!/bin/bash -eE

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$functions"

trap 'catch_errors_ce $LINENO' ERR EXIT
function catch_errors_ce() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

# version 2
PLACE="--series=$SERIES $WORKSPACE/contrail-charms"

comp1_ip="$addr.$os_comp_1_idx"
comp1=`get_machine_by_ip $comp1_ip`
echo "INFO: compute 1: $comp1 / $comp1_ip"
comp2_ip="$addr.$os_comp_2_idx"
comp2=`get_machine_by_ip $comp2_ip`
echo "INFO: compute 2: $comp2 / $comp2_ip"

cont0_ip="$addr.$os_cont_0_idx"
cont0=`get_machine_by_ip $cont0_ip`
echo "INFO: controller 0: $cont0 / $cont0_ip"

( set -o posix ; set ) > $log_dir/env
echo "INFO: Deploy all $(date)"

### deploy applications

# kubernetes

juju-deploy cs:~containers/easyrsa easyrsa --to lxd:2

juju-deploy cs:~containers/etcd etcd --to 2 \
    --resource etcd=3 \
    --resource snapshot=0
juju-set etcd channel="3.2/stable"

juju-deploy cs:~containers/kubernetes-master kubernetes-master --to 2 \
    --resource cdk-addons=0 \
    --resource kube-apiserver=0 \
    --resource kube-controller-manager=0 \
    --resource kube-proxy=0 \
    --resource kube-scheduler=0 \
    --resource kubectl=0
juju-set kubernetes-master channel="1.14/stable" \
    enable-dashboard-addons="false" \
    enable-metrics="false" \
    dns-provider="none" \
    docker_runtime=$DOCKER_RUNTIME

juju-expose kubernetes-master

juju-deploy cs:~containers/kubernetes-worker kubernetes-worker --to 2 \
    --resource cni-amd64="154" \
    --resource cni-arm64="146" \
    --resource cni-s390x="152" \
    --resource kube-proxy="0" \
    --resource kubectl="0" \
    --resource kubelet="0"
juju-set kubernetes-worker channel="1.14/stable" \
    ingress="false" \
    docker_runtime=$DOCKER_RUNTIME
juju-expose kubernetes-worker

# contrail-kubernetes

juju-deploy $PLACE/contrail-kubernetes-master contrail-kubernetes-master --config log-level=SYS_DEBUG --to 2
juju-set contrail-kubernetes-master docker-registry=$CONTAINER_REGISTRY image-tag=$CONTRAIL_VERSION \
    docker-user=$DOCKER_USERNAME docker-password=$DOCKER_PASSWORD docker_runtime=$DOCKER_RUNTIME

juju-deploy $PLACE/contrail-kubernetes-node contrail-kubernetes-node --config log-level=SYS_DEBUG
juju-set contrail-kubernetes-node docker-registry=$CONTAINER_REGISTRY image-tag=$CONTRAIL_VERSION \
    docker-user=$DOCKER_USERNAME docker-password=$DOCKER_PASSWORD docker_runtime=$DOCKER_RUNTIME

# contrail

juju-deploy $PLACE/contrail-agent contrail-agent --config log-level=SYS_DEBUG
juju-set contrail-kubernetes-node docker-registry=$CONTAINER_REGISTRY image-tag=$CONTRAIL_VERSION \
    docker-user=$DOCKER_USERNAME docker-password=$DOCKER_PASSWORD docker_runtime=$DOCKER_RUNTIME

juju-deploy $PLACE/contrail-analytics contrail-analytics --config log-level=SYS_DEBUG --to 2
juju-set contrail-analytics docker-registry=$CONTAINER_REGISTRY image-tag=$CONTRAIL_VERSION \
    docker-user=$DOCKER_USERNAME docker-password=$DOCKER_PASSWORD docker_runtime=$DOCKER_RUNTIME
juju-expose contrail-analytics

juju-deploy $PLACE/contrail-analyticsdb contrail-analyticsdb --config log-level=SYS_DEBUG --to 2
juju-set contrail-analyticsdb docker-registry=$CONTAINER_REGISTRY image-tag=$CONTRAIL_VERSION \
    docker-user=$DOCKER_USERNAME docker-password=$DOCKER_PASSWORD docker_runtime=$DOCKER_RUNTIME \
    cassandra-minimum-diskgb="4" cassandra-jvm-extra-opts="-Xms1g -Xmx2g"

juju-deploy $PLACE/contrail-controller contrail-controller --config log-level=SYS_DEBUG --to 2
juju-set contrail-controller docker-registry=$CONTAINER_REGISTRY image-tag=$CONTRAIL_VERSION \
    docker-user=$DOCKER_USERNAME docker-password=$DOCKER_PASSWORD docker_runtime=$DOCKER_RUNTIME \
    cassandra-minimum-diskgb="4" cassandra-jvm-extra-opts="-Xms1g -Xmx2g" auth-mode="no-auth"
juju-expose contrail-controller

# misc

juju-deploy cs:xenial/ntp ntp

m4=$cont0
m2=$comp1
m3=$comp2
wait_for_machines $m2 $m3 $m4
echo "INFO: Apply SSL flag if set $(date)"
apply_ssl contrail

# re-write resolv.conf for bionic lxd containers to allow names resolving inside lxd containers
if [[ "$SERIES" == 'bionic' ]]; then
  for mmch in `juju machines | awk '/lxd/{print $1}'` ; do
    echo "INFO: apply DNS config for $mmch"
    res=1
    for i in 0 1 2 3 4 5 ; do
      if juju-ssh $mmch "echo 'nameserver $addr.1' | sudo tee /usr/lib/systemd/resolv.conf ; sudo ln -sf /usr/lib/systemd/resolv.conf /etc/resolv.conf" ; then
        res=0
        break
      fi
      sleep 10
    done
    test $res -eq 0 || { echo "ERROR: Machine $mmch is not accessible"; exit 1; }
  done
fi

### add charms relations

# kubernetes

juju-add-relation "kubernetes-master:kube-api-endpoint" "kubernetes-worker:kube-api-endpoint"
juju-add-relation "kubernetes-master:kube-control" "kubernetes-worker:kube-control"
juju-add-relation "kubernetes-master:certificates" "easyrsa:client"
juju-add-relation "kubernetes-master:etcd" "etcd:db"
juju-add-relation "kubernetes-worker:certificates" "easyrsa:client"
juju-add-relation "etcd:certificates" "easyrsa:client"

# contrail-kubernetes

juju-add-relation "contrail-kubernetes-node:cni" "kubernetes-master:cni"
juju-add-relation "contrail-kubernetes-node:cni" "kubernetes-worker:cni"
juju-add-relation "contrail-kubernetes-master:contrail-controller" "contrail-controller:contrail-controller"
juju-add-relation "contrail-kubernetes-master:kube-api-endpoint" "kubernetes-master:kube-api-endpoint"
juju-add-relation "contrail-agent:juju-info" "kubernetes-worker:juju-info"
juju-add-relation "contrail-kubernetes-master:contrail-kubernetes-config" "contrail-kubernetes-node:contrail-kubernetes-config"

# contrail

juju-add-relation "contrail-controller" "contrail-analytics"
juju-add-relation "contrail-controller" "contrail-analyticsdb"
juju-add-relation "contrail-analytics" "contrail-analyticsdb"
juju-add-relation "contrail-agent" "contrail-controller"
juju-add-relation "contrail-controller" "ntp"

post_deploy

trap - ERR EXIT
