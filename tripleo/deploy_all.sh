#!/bin/bash -e

# first param is a path to script that can check it all

# first param for the script - ssh addr to undercloud
# other params - ssh opts
check_script="$1"
my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

NUM=${NUM:-0}
BASE_ADDR=${BASE_ADDR:-172}
((env_addr=BASE_ADDR+NUM*10))
ip_addr="192.168.${env_addr}.2"
ssh_opts="-i $my_dir/kp-$NUM -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ssh_addr="root@${ip_addr}"

trap 'catch_errors $LINENO' ERR

oc=0
function save_overcloud_logs() {
  if [[ $oc == 1 ]] ; then
    ssh -t $ssh_opts $ssh_addr "sudo -u stack /home/stack/save_logs.sh"
  fi
}

function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR

  # sleep some time to flush logs
  sleep 20
  save_overcloud_logs

  exit $exit_code
}


echo "INFO: creating environment $(date)"
"$my_dir"/create_env.sh
if [[ -n "$SUDO_USER" ]] ; then
  chown $SUDO_USER:$SUDO_GID $my_dir/kp-$NUM*
fi
echo "INFO: installing undercloud $(date)"
"$my_dir"/undercloud-install.sh

echo "INFO: installing overcloud $(date)"
oc=1
ssh -t $ssh_opts $ssh_addr "sudo -u stack NUM=$NUM DEPLOY=1 /home/stack/overcloud-install.sh"

echo "INFO: checking overcloud $(date)"
if [[ -n "$check_script" ]] ; then
  $check_script $ssh_addr $ssh_opts
else
  echo "WARNING: Deployment will not be checked!"
fi


trap - ERR
save_overcloud_logs
