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

# detect IP-s - place all things to specified interface for now
control_network_cfg=""
name_resolution_cfg=""
if [[ "$PHYS_INT" == 'ens4' ]]; then
  # hard-coded definition...
  control_network_cfg="--config control-network=$addr_vm.0/24"
  name_resolution_cfg="--config local-rabbitmq-hostname-resolution=true"
fi

# version 2
PLACE="--series=$SERIES $WORKSPACE/tf-charms"

comp1_ip="$addr.$comp_1_idx"
comp1=`get_machine_by_ip $comp1_ip`
echo "INFO: compute 1: $comp1 / $comp1_ip"
### TODO: remove it when second will be used for vhost0. currently virsh loses DNS record for compute when vhost0 is come up
juju-ssh $comp1 "sudo bash -c 'echo $comp1_ip $job_prefix-comp-1 >> /etc/hosts'" 2>/dev/null

cont0_ip="$addr.$cont_0_idx"
cont0=`get_machine_by_ip $cont0_ip`
echo "INFO: controller 0: $cont0 / $cont0_ip"
cont1_ip="$addr.$cont_1_idx"
cont1=`get_machine_by_ip $cont1_ip`
echo "INFO: controller 1: $cont1 / $cont1_ip"

( set -o posix ; set ) > $log_dir/env
echo "INFO: Deploy all $(date)"

### deploy applications
# kubernetes
juju-deploy --series $SERIES cs:~containers/easyrsa --to lxd:$cont0
juju-deploy --series $SERIES cs:~containers/etcd --to $cont0 --config channel="3.2/stable"

juju-deploy --series $SERIES cs:~containers/kubernetes-master-696 --to $cont0 \
  --config channel="1.14/stable" \
  --config enable-metrics="false" \
  --config service-cidr="10.96.0.0/12" \
  --config docker_runtime="custom" \
  --config docker_runtime_repo="deb [arch={ARCH}] https://download.docker.com/linux/ubuntu {CODE} stable" \
  --config docker_runtime_key_url="https://download.docker.com/linux/ubuntu/gpg" \
  --config docker_runtime_package="docker-ce"
juju-expose kubernetes-master

juju-deploy --series $SERIES cs:~containers/kubernetes-worker-550 --to $comp1 \
  --config channel="1.14/stable" \
  --config ingress="false" \
  --config docker_runtime="custom" \
  --config docker_runtime_repo="deb [arch={ARCH}] https://download.docker.com/linux/ubuntu {CODE} stable" \
  --config docker_runtime_key_url="https://download.docker.com/linux/ubuntu/gpg" \
  --config docker_runtime_package="docker-ce"

docker_opts="--config docker-registry=$CONTAINER_REGISTRY --config image-tag=$CONTRAIL_VERSION --config docker-user=$DOCKER_USERNAME --config docker-password=$DOCKER_PASSWORD --config docker-registry-insecure=true"

# contrail-kubernetes
juju-deploy $PLACE/contrail-kubernetes-master --config log-level=SYS_DEBUG --config "service_subnets=10.96.0.0/12" $control_network_cfg $docker_opts
juju-deploy $PLACE/contrail-kubernetes-node --config log-level=SYS_DEBUG $docker_opts

# contrail
juju-deploy $PLACE/contrail-agent --config log-level=SYS_DEBUG --config physical-interface=$PHYS_INT $docker_opts

juju-deploy $PLACE/contrail-analytics --config log-level=SYS_DEBUG --to $cont1 $control_network_cfg $docker_opts
juju-expose contrail-analytics

juju-deploy $PLACE/contrail-analyticsdb --config log-level=SYS_DEBUG --to $cont1 $control_network_cfg $docker_opts
juju-set contrail-analyticsdb cassandra-minimum-diskgb="4" cassandra-jvm-extra-opts="-Xms1g -Xmx2g"

juju-deploy $PLACE/contrail-controller --config log-level=SYS_DEBUG --to $cont1 $control_network_cfg $name_resolution_cfg $docker_opts
juju-set contrail-controller cassandra-minimum-diskgb="4" cassandra-jvm-extra-opts="-Xms1g -Xmx2g" auth-mode="no-auth"
juju-expose contrail-controller

# misc
juju-deploy cs:$SERIES/ntp

wait_for_machines $cont0 $cont1 $comp1
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
juju-add-relation "kubernetes-master" "ntp"
juju-add-relation "kubernetes-worker" "ntp"
juju-add-relation "contrail-controller" "ntp"

# kubernetes
juju-add-relation "kubernetes-master:kube-api-endpoint" "kubernetes-worker:kube-api-endpoint"
juju-add-relation "kubernetes-master:kube-control" "kubernetes-worker:kube-control"
juju-add-relation "kubernetes-master:certificates" "easyrsa:client"
juju-add-relation "kubernetes-master:etcd" "etcd:db"
juju-add-relation "kubernetes-worker:certificates" "easyrsa:client"
juju-add-relation "etcd:certificates" "easyrsa:client"

# contrail
juju-add-relation "contrail-controller" "contrail-analytics"
juju-add-relation "contrail-controller" "contrail-analyticsdb"
juju-add-relation "contrail-analytics" "contrail-analyticsdb"
juju-add-relation "contrail-agent" "contrail-controller"

# contrail-kubernetes
juju-add-relation "contrail-kubernetes-node:cni" "kubernetes-master:cni"
juju-add-relation "contrail-kubernetes-node:cni" "kubernetes-worker:cni"
juju-add-relation "contrail-kubernetes-master:contrail-controller" "contrail-controller:contrail-controller"
juju-add-relation "contrail-kubernetes-master:kube-api-endpoint" "kubernetes-master:kube-api-endpoint"
juju-add-relation "contrail-agent:juju-info" "kubernetes-worker:juju-info"
juju-add-relation "contrail-kubernetes-master:contrail-kubernetes-config" "contrail-kubernetes-node:contrail-kubernetes-config"

post_deploy

trap - ERR EXIT
