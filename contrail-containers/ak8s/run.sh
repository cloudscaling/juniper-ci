#!/bin/bash -ea

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [[ "$CLEAN_BEFORE" == 'true' || "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh || /bin/true
  if [[ "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
    exit
  fi
fi

rm -rf "$WORKSPACE/logs"
mkdir -p "$WORKSPACE/logs"

# definition for job deployment
source $my_dir/${HOST}-defs
source $my_dir/../common/functions
source $my_dir/../common/check-functions

$my_dir/../common/${HOST}/create-vm.sh
source "$my_dir/../common/${HOST}/setup-defs"

trap 'catch_errors $LINENO' ERR
function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"

  save_logs '1-'
  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    $my_dir/../common/${HOST}/cleanup.sh
  fi

  exit $exit_code
}

if [[ "$CONTAINER_REGISTRY" == 'build' || "$CONTAINER_REGISTRY" == 'fullbuild' ]]; then
  build_containers
  CONTAINER_REGISTRY="$build_ip:5000"
  CONTRAIL_VERSION="$OPENSTACK_VERSION-$CONTRAIL_VERSION"
fi

# deploy cloud
source "$my_dir/../common/${HOST}/${ENVIRONMENT_OS}"

IP_CONT_01=`echo $nodes_cont_ips | cut -d ' ' -f 1`
IP_CONT_02=`echo $nodes_cont_ips | cut -d ' ' -f 2`
IP_CONT_03=`echo $nodes_cont_ips | cut -d ' ' -f 3`
IP_COMP_01=`echo $nodes_comp_ips | cut -d ' ' -f 1`
IP_COMP_02=`echo $nodes_comp_ips | cut -d ' ' -f 2`

# aws has different IP for internal and public purposes. while IP_* are public then they can't be used as services' IP-s.
# containers can't find the public IP in local IP-s list and fail.
# empty value was not tested - fill it always
CONTROLLER_NODES="$(echo $nodes_cont_ips_0 | tr ' ' ',')"

config=$WORKSPACE/contrail-ansible-deployer/instances.yaml
envsubst <$my_dir/instances.yaml.${HA}.tmpl >$config
echo "INFO: cloud config ------------------------- $(date)"
cat $config
cp $config $WORKSPACE/logs/
$SCP $config ${SSH_USER}@${master_ip}:

prepare_image centos-soft

mkdir -p $WORKSPACE/logs/deployer
volumes="-v $WORKSPACE/contrail-ansible-deployer:/root/contrail-ansible-deployer"
volumes+=" -v $HOME/.ssh:/.ssh"
volumes+=" -v $WORKSPACE/logs/deployer:/root/logs"
volumes+=" -v $my_dir/__run-gate.sh:/root/run-gate.sh"
docker run -i --rm --entrypoint /bin/bash $volumes --network host centos-soft -c "/root/run-gate.sh"

# TODO: wait till cluster up and initialized
sleep 300

check_introspection_cloud

function check_cluster() {
  tmpf=`mktemp`
  cat <<EOM > $tmpf
#!/bin/bash -x
kubectl create serviceaccount --namespace kube-system tiller
kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
wget -nv https://storage.googleapis.com/kubernetes-helm/helm-v2.9.0-linux-amd64.tar.gz
tar -xvf helm-v2.9.0-linux-amd64.tar.gz
mv linux-amd64/helm /usr/bin/
helm init
kubectl patch deploy --namespace kube-system tiller-deploy -p '{"spec":{"template":{"spec":{"serviceAccount":"tiller", "automountServiceAccountToken": true}}}}'
helm init --service-account tiller --upgrade
sleep 60
helm version
kubectl get pods --all-namespaces
helm repo update
helm install --name wordpress --set mariadb.master.persistence.enabled=false --set persistence.enabled=false stable/wordpress
sleep 90
kubectl get pods
kubectl get svc wordpress-wordpress
set +x
EOM
  $SCP $tmpf ${SSH_USER}@${master_ip}:check_k8s.sh
  rm $tmpf
  $SSH_CMD ${SSH_USER}@${master_ip} "sudo /bin/bash check_k8s.sh"

  # this is needed if we want to enable persistence
  # ? helm repo add nfs-provisioner https://raw.githubusercontent.com/IlyaSemenov/nfs-provisioner-chart/master/repo
  # ? helm install --name nfs-provisioner --namespace nfs-provisioner nfs-provisioner/nfs-provisioner && sleep 5
  # ? kubectl patch storageclass local-nfs -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
}

check_cluster

# save logs and exit
trap - ERR
save_logs '1-'
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi

exit $res
