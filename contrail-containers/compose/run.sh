#!/bin/bash -ex

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
export NET_ADDR=${NET_ADDR:-"10.1.$JOB_RND.0"}

function save_logs() {
  source "$my_dir/../common/${HOST}/ssh-defs"
  set +e
  # save common docker logs
  for dest in ${SSH_DEST_WORKERS[@]} ; do
    # TODO: when repo be splitted to containers & build here will be containers repo only,
    # then build repo should be added to be copied below
    timeout -s 9 20s $SCP "$my_dir/../__save-docker-logs.sh" ${dest}:save-docker-logs.sh
    if [[ $? == 0 ]] ; then
      ssh -i $ssh_key_file $SSH_OPTS ${dest} "./save-docker-logs.sh"
    fi
  done

  # save env host specific logs
  # (should save into ~/logs folder on the SSH host)
  $my_dir/../common/${HOST}/save-logs.sh

  # save to workspace
  for dest in ${SSH_DEST_WORKERS[@]} ; do
    if timeout -s 9 30s ssh -i $ssh_key_file $SSH_OPTS ${dest} "sudo tar -cf logs.tar ./logs ; gzip logs.tar" ; then
      local lname=$(echo $dest | cut -d '@' -f 2)
      mkdir -p "$WORKSPACE/logs/$lname"
      timeout -s 9 10s $SCP ${dest}:logs.tar.gz "$WORKSPACE/logs/${lname}/logs.tar.gz"
      pushd "$WORKSPACE/logs/$lname"
      tar -xf logs.tar.gz
      rm logs.tar.gz
      popd
    fi
  done

  # save to workspace
  if timeout -s 9 30s $SSH_BUILD "sudo tar -cf logs.tar ./logs ; gzip logs.tar" ; then
    timeout -s 9 10s $SCP $SSH_DEST_BUILD:logs.tar.gz "$WORKSPACE/logs/build_logs.tar.gz"
    pushd "$WORKSPACE/logs"
    tar -xf build_logs.tar.gz
    rm build_logs.tar.gz
    popd
  fi
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
  $SCP -r "$WORKSPACE/contrail-ansible-deployer" ${dest}:./
  $SCP "$my_dir/../__check_rabbitmq.sh" ${dest}:check_rabbitmq.sh
  $SCP "$my_dir/../__check_introspection.sh" ${dest}:./check_introspection.sh
done
$my_dir/setup-nodes.sh

$SCP "$my_dir/../__build-containers.sh" $SSH_DEST_BUILD:build-containers.sh

set -o pipefail
ssh_env="CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION"
ssh_env+=" CONTRAIL_INSTALL_PACKAGES_URL=$CONTRAIL_INSTALL_PACKAGES_URL"
ssh_env+=" AGENT_MODE=$AGENT_MODE"
$SSH_BUILD "$ssh_env timeout -s 9 180m ./build-containers.sh" |& tee $WORKSPACE/logs/build.log
set +o pipefail

$SCP "$my_dir/__run-gate.sh" $SSH_DEST:run-gate.sh
timeout -s 9 60m $SSH "CONTRAIL_VERSION=$CONTRAIL_VERSION AGENT_MODE=$AGENT_MODE ./run-gate.sh $public_ip_build"

# Validate cluster
# TODO: rename run-gate since now check of cluster is here. no. move this code to run-gate or another file.
source "$my_dir/../common/check-functions"
dest_to_check=$(echo ${SSH_DEST_WORKERS[@]:0:3} | sed 's/ /,/g')

# TODO: wait till cluster up and initialized
sleep 300
res=0
if ! check_rabbitmq_cluster "$dest_to_check" ; then
  # TODO: temporary disable rabbit claster check"
  echo "ERROR: rebbitmq cluster check was faild"
  res=1
fi

dest_to_check=$(echo ${SSH_DEST_WORKERS[@]} | sed 's/ /,/g')
expected_number_of_services=41
count=1
limit=3
while ! check_introspection $expected_number_of_services "$dest_to_check" ; do
  echo "INFO: check_introspection ${count}/${limit} failed"
  if (( count == limit )) ; then
    res=1
    break
  fi
  (( count+=1 ))
  sleep 10
done

trap - ERR
save_logs
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi

return $res