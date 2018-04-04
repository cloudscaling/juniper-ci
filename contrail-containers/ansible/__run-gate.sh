#!/bin/bash -ex

function log_info() {
  echo "INFO: $@"
}

function log_error() {
  echo "ERROR: $@"
}

# ip is located in /usr/sbin that is not in path...
export PATH=${PATH}:/usr/sbin

function wait_cluster() {
  local name=$1
  local pods_rgx=$2
  log_info "Wait $name up.."
  local total=0
  local running=0
  local i=0
  for (( i=0 ; i < 120 ; ++i )) ; do
    sleep 5
    (( total=1 + $(docker ps --all | grep -c "$pods_rgx") ))
     (( running=1 + $(docker ps | grep -c "$pods_rgx") ))
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
pushd ~/contrail-ansible-deployer
ansible-playbook -i inventory/ playbooks/deploy.yml
popd
wait_cluster "Contrail" "contrail\|zookeeper\|rabbit\|kafka\|redis\|cassandra"

wait_contrail_sec=60
log_info "Wait Contrail cluster to up till $wait_contrail_sec seconds..."
sleep $wait_contrail_sec

log_info "TODO: Run test application: nginx"
#wait_cluster "nginx" "nginx"

# TODO: test connectivities
