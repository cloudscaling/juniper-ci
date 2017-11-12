#!/bin/bash -ex

export CONTRAIL_VERSION=${CONTRAIL_VERSION:-'4.0.2.0-35'}
export EXTERNAL_K8S_AGENT=${EXTERNAL_K8S_AGENT:-'docker.io/opencontrail/contrail-kubernetes-agent-ubuntu16.04:4.0.1.0'}
export DOCKER_REGISTRY_ADDR=${DOCKER_REGISTRY_ADDR:-''}

# to find ip tool
export PATH=${PATH}:/usr/sbin

function log_info() {
  echo "INFO: $@"
}

function log_error() {
  echo "ERROR: $@"
}

log_info "setup k8s ..."
pushd contrail-container-builder
kubernetes/setup-k8s.sh

iface=`ip -4 route list 0/0 | awk '{ print $5; exit }'`
local_ip=`ip addr | grep $iface | grep 'inet ' | awk '{print $2}' | cut -d '/' -f 1`
log_info "iface=$iface local_ip=$local_ip"

docker_registry=$DOCKER_REGISTRY_ADDR
if [[ -z "$docker_registry" ]] ; then
  docker_registry="${local_ip}:5000"
fi
log_info "docker_registry=$docker_registry"

if [[ -n "$EXTERNAL_K8S_AGENT" ]] ; then
  log_info "pull external contrail agent: $EXTERNAL_K8S_AGENT"
  docker pull $EXTERNAL_K8S_AGENT
  kubernetes_agent_fname=$(echo "$EXTERNAL_K8S_AGENT" | awk -F '/' '{print($NF)}')
  kubernetes_agent_name=$(echo $kubernetes_agent_fname | cut -d ':' -f 1)
  log_info "set tag: ${docker_registry}/${kubernetes_agent_name}:${CONTRAIL_VERSION}"
  docker tag $EXTERNAL_K8S_AGENT ${docker_registry}/${kubernetes_agent_name}:${CONTRAIL_VERSION}
  log_info "set tag: ${docker_registry}/${kubernetes_agent_fname}"
  docker tag $EXTERNAL_K8S_AGENT ${docker_registry}/${kubernetes_agent_fname}
fi

cat <<EOF > common.env
HOST_IP=$local_ip
PHYSICAL_INTERFACE=$iface
CONTRAIL_VERSION=$CONTRAIL_VERSION
EOF

log_info "common.env:"
cat common.env

pushd kubernetes/manifests/
./resolve-manifest.sh <contrail-micro.yaml >~/my-contrail-micro.yaml
popd

popd

function wait_cluster() {
  local name=$1
  local pods_rgx=$2
  log_info "Wait $name up.."
  local total=0
  local running=0
  local i=0
  for (( i=0 ; i < 600 ; ++i )) ; do
    (( total=1 + $(kubectl get pods --all-namespaces=true | grep -c "$pods_rgx") ))
     (( running=1 + $(kubectl get pods --all-namespaces=true | grep "$pods_rgx" | grep -ic 'running') ))
    log_info "  components up: ${running}/${total}"
    if (( total != 1 && total == running )) ; then
      log_info "$name is running"
      break
    fi
  done
  if (( total != running )) ; then
    log_error "$name failed to run till timeout"
    exit -1
  fi
}

log_info "create Contrail cluster"
kubectl create -f ~/my-contrail-micro.yaml
wait_cluster "Contrail" "contrail\|zookeeper\|rabbit\|kafka\|redis"

log_info "Run test application: nginx"
cat <<EOF > ~/test_app.yaml
apiVersion: apps/v1beta1 # for versions before 1.8.0 use apps/v1beta1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  selector:
    matchLabels:
      app: nginx
  replicas: 1 # tells deployment to run 2 pods matching the template
  template: # create pods using pod definition in this template
    metadata:
      # unlike pod-nginx.yaml, the name is not included in the meta data as a unique name is
      # generated from the deployment name
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.7.9
        ports:
        - containerPort: 80
      tolerations:
      - operator: "Exists"
        effect: "NoSchedule"
EOF

log_info "run test application"
kubectl create -f ~/test_app.yaml
wait_cluster "nginx" "nginx"

# TODO: test connectivities
