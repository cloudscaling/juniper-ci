#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [[ -z "$WORKSPACE" ]] ; then
  echo "Please set WORKSPACE variable"
  exit 1
fi

export NUM=${NUM:-0}
export ENVIRONMENT_OS=${ENVIRONMENT_OS:-'centos'}
export CLEAN_ENV=${CLEAN_ENV:-'auto'}
export OPENSTACK_VERSION=${OPENSTACK_VERSION:-'newton'}
export CONTROLLER_COUNT=${CONTROLLER_COUNT:-1}
export NETWORK_ISOLATION=${NETWORK_ISOLATION:-'single'}
export USE_DEVELOPMENT_PUPPETS=${USE_DEVELOPMENT_PUPPETS:-true}
export SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30"
export DVR=${DVR:-'true'}

function cleanup_environment() {
  ${my_dir}/clean_env.sh
}

function save_logs() {
  if [[ -z "$MGMT_IP" ]] ;then
    echo "ERROR: no MGMT_IP, it looks create env was not successful"
    return
  fi
  rm -rf logs
  mkdir logs
  local ssh_addr=root@${MGMT_IP}
  scp $SSH_OPTS $ssh_addr:/home/stack/heat.log logs/heat.log
  for lf in `ssh $ssh_opts $ssh_addr ls /home/stack/*-logs.tar` ; do
    local nm=`echo $lf | rev | cut -d '/' -f 1 | rev`
    scp $SSH_OPTS $ssh_addr:$lf $nm
    mkdir logs/$nm
    tar xf $nm -C logs/$nm
  done
  # patch +x flag for next archiving, rhcert doesnt have it
  chmod -R +x logs
}

function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR

  # sleep some time to flush logs
  sleep 20
  save_logs

  if [[ $CLEAN_ENV == 'always' ]] ; then
    cleanup_environment
  fi

  exit $exit_code
}

trap 'catch_errors $LINENO' ERR

if [[ $CLEAN_ENV != 'never' ]] ; then
  cleanup_environment
fi

source ${my_dir}/deploy_all.sh "${my_dir}/check-openstack-proxy.sh"

trap - ERR

save_logs

if [[ $CLEAN_ENV != 'never' && $CLEAN_ENV != 'before_only' ]] ; then
  cleanup_environment
fi
