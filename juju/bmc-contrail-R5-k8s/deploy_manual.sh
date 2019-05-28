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

# deploy

# contrail-kubernetes
juju-deploy $PLACE/contrail-kubernetes-master contrail-kubernetes-master --to 2
juju-deploy $PLACE/contrail-kubernetes-node contrail-kubernetes-node 

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

post_deploy

trap - ERR EXIT
