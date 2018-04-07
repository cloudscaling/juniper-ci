#!/bin/bash -e

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

# definition for baremetal deployment
export JOB_RND=$((RANDOM % 100))
export NET_ADDR=${NET_ADDR:-"10.9.$JOB_RND.0"}
export NET_PREFIX=$(echo $NET_ADDR | cut -d '.' -f 1,2,3)
export NET_ADDR_VR=${NET_ADDR_VR:-"10.10.$JOB_RND.0"}

function save_logs() {
  source "$my_dir/../common/${HOST}/ssh-defs"
  set +e
  # save common docker logs
  for dest in ${SSH_DEST_WORKERS[@]} ; do
    # TODO: when repo be splitted to containers & build here will be containers repo only,
    # then build repo should be added to be copied below
    timeout -s 9 20s $SCP "$my_dir/../__save-docker-logs.sh" ${dest}:save-docker-logs.sh
    if [[ $? == 0 ]] ; then
      ssh -i $ssh_key_file $SSH_OPTS ${dest} "CNT_NAME_PATTERN='1-' ./save-docker-logs.sh"
    fi
  done

  # save env host specific logs
  # (should save into ~/logs folder on the SSH host)
  $my_dir/../common/${HOST}/save-logs.sh

  # save to workspace
  for dest in ${SSH_DEST_WORKERS[@]} ; do
    if timeout -s 9 30s ssh -i $ssh_key_file $SSH_OPTS ${dest} "sudo tar -cf logs.tar ./logs ; gzip logs.tar" ; then
      local lname=$(echo $dest | cut -d '@' -f 2)
      local ldir="$WORKSPACE/logs/$lname"
      mkdir -p "$ldir"
      timeout -s 9 10s $SCP ${dest}:logs.tar.gz "$ldir/logs.tar.gz"
      pushd "$ldir"
      tar -xf logs.tar.gz
      rm logs.tar.gz
      popd
    fi
  done
}

trap catch_errors ERR;
function catch_errors() {
  local exit_code=$?
  echo "Errors!" $exit_code $@

  save_logs
  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    $my_dir/../common/${HOST}/cleanup.sh
  fi

  exit $exit_code
}

# Work with docker-compose udner root
export SSH_USER=root
$my_dir/../common/${HOST}/create-vm.sh
source "$my_dir/../common/${HOST}/ssh-defs"

for dest in ${SSH_DEST_WORKERS[@]} ; do
  # TODO: when repo be splitted to containers & build here will be containers repo only,
  # then build repo should be added to be copied below
  $SCP -r "$WORKSPACE/contrail-container-builder" ${dest}:./
  $SCP "$my_dir/../__check_rabbitmq.sh" ${dest}:check_rabbitmq.sh
  $SCP "$my_dir/../__check_introspection.sh" ${dest}:./check_introspection.sh
done

if [[ "$REGISTRY" == 'build' || -z "$REGISTRY" ]]; then
  $SCP "$my_dir/../__build-containers.sh" $SSH_DEST_BUILD:build-containers.sh
  set -o pipefail
  ssh_env="CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION"
  ssh_env+=" CONTRAIL_INSTALL_PACKAGES_URL=$CONTRAIL_INSTALL_PACKAGES_URL"
  $SSH_BUILD "$ssh_env timeout -s 9 180m ./build-containers.sh" |& tee $WORKSPACE/logs/build.log
  set +o pipefail
elif [[ "$REGISTRY" == 'opencontrailnightly' ]]; then
  CONTAINER_REGISTRY='opencontrailnightly'
  CONTRAIL_VERSION='latest'
else
  echo "ERROR: unsupported REGISTRY = $REGISTRY"
  exit 1
fi

source "$my_dir/../common/${HOST}/${ENVIRONMENT_OS}"

IP_CONT_01=`echo ${SSH_DEST_WORKERS[0]} | cut -d '@' -f 2`
IP_CONT_02=`echo ${SSH_DEST_WORKERS[1]} | cut -d '@' -f 2`
IP_CONT_03=`echo ${SSH_DEST_WORKERS[2]} | cut -d '@' -f 2`
IP_COMP_01=`echo ${SSH_DEST_WORKERS[3]} | cut -d '@' -f 2`
CONTRAIL_REGISTRY=$IP_CONT_01
IP_VIP=${NET_PREFIX}.254
IP_GW=${NET_PREFIX}.1

cat <<EOF > $WORKSPACE/contrail-ansible-deployer/inventory/hosts
container_hosts:
  hosts:
    $IP_CONT_01:
    $IP_CONT_02:
    $IP_CONT_03:
    $IP_COMP_01:
EOF

config=$WORKSPACE/contrail-ansible-deployer/instances.yaml
templ=$(cat $my_dir/instances.yaml.tmpl)
content=$(eval "echo \"$templ\"")
echo "$content" > $config

image=`docker images -a -q centos-soft`
if [[ -z "$image" ]]; then
  docker pull centos
  docker run -i --name cprep-$JOB_RND --entrypoint /bin/bash centos -c "yum install -y epel-release && yum install -y ansible python-ipaddress git python-pip sudo vim gcc python-devel && pip install pip --upgrade && pip install pycrypto oslo_utils oslo_config jinja2"
  docker commit cprep-$JOB_RND centos-soft
  docker rm cprep-$JOB_RND
fi

kolla_dir="$WORKSPACE/etc-kolla"
rm -rf $kolla_dir && mkdir -p $kolla_dir
ansible_dir="$WORKSPACE/etc-ansible"
rm -rf $ansible_dir && mkdir -p $ansible_dir
volumes="-v $WORKSPACE/contrail-ansible-deployer:/root/contrail-ansible-deployer"
volumes+=" -v $HOME/.ssh:/.ssh"
volumes+=" -v $my_dir/__run-gate.sh:/root/run-gate.sh"
volumes+=" -v $kolla_dir:/etc/kolla"
volumes+=" -v $ansible_dir:/etc/ansible"
docker run -i --entrypoint /bin/bash $volumes --network host centos-soft -c "/root/run-gate.sh"


# Validate cluster
# TODO: rename run-gate since now check of cluster is here. no. move this code to run-gate or another file.
source "$my_dir/../common/check-functions"
dest_to_check=$(echo ${SSH_DEST_WORKERS[@]:0:3} | sed 's/ /,/g')

# TODO: wait till cluster up and initialized
sleep 300
res=0

dest_to_check=$(echo ${SSH_DEST_WORKERS[@]} | sed 's/ /,/g')
count=1
limit=3
while ! check_introspection "$dest_to_check" ; do
  echo "INFO: check_introspection ${count}/${limit} failed"
  if (( count == limit )) ; then
    echo "ERROR: Cloud was not up during timeout"
    res=1
    break
  fi
  (( count+=1 ))
  sleep 30
done

trap - ERR
save_logs
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi

exit $res
