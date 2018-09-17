#!/bin/bash -ex

# first param is a path to script that can check it all

# first param for the script - ssh addr to undercloud
# other params - ssh opts
check_script="$1"
my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ssh_key_dir="/home/jenkins/.ssh"

NUM=${NUM:-0}
NETWORK_ISOLATION=${NETWORK_ISOLATION:-'single'}

BASE_ADDR=${BASE_ADDR:-172}
((env_addr=BASE_ADDR+NUM*10))
ip_addr="192.168.${env_addr}.2"
ssh_opts="-i $ssh_key_dir/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
ssh_addr="root@${ip_addr}"

# TODO: place all definitions here

# Dir with contrail packages
export CONTRAIL_PACKAGES_DIR=${CONTRAIL_PACKAGES_DIR:-"/home/jenkins/cache"}

trap 'catch_errors $LINENO' ERR

oc=0
function save_overcloud_logs() {
  if [[ $oc == 1 ]] ; then
    ssh -T $ssh_opts $ssh_addr "sudo -u stack /home/stack/save_logs.sh"
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

ssh_env="NUM=$NUM DEPLOY=1 NETWORK_ISOLATION=$NETWORK_ISOLATION"
ssh_env+=" ENVIRONMENT_OS=$ENVIRONMENT_OS ENVIRONMENT_OS_VERSION=$ENVIRONMENT_OS_VERSION"
ssh_env+=" OPENSTACK_VERSION=$OPENSTACK_VERSION RHEL_CERT_TEST=$RHEL_CERT_TEST"
ssh_env+=" TLS=$TLS DPDK=$DPDK TSN=$TSN SRIOV=$SRIOV"
ssh_env+=" KEYSTONE_API_VERSION=$KEYSTONE_API_VERSION"
ssh_env+=" AAA_MODE=$AAA_MODE AAA_MODE_ANALYTICS=$AAA_MODE_ANALYTICS"
ssh_env+=" USE_DEVELOPMENT_PUPPETS=$USE_DEVELOPMENT_PUPPETS CONTRAIL_VERSION=$CONTRAIL_VERSION"
ssh_env+=" FREE_IPA=$FREE_IPA"
if [[ -f $CONTRAIL_PACKAGES_DIR/tag ]] ; then
  build_tag=`cat $CONTRAIL_PACKAGES_DIR/tag`
  ssh_env+=" BUILD_TAG=$build_tag"
fi
[ -n "$CCB_PATCHSET" ] && ssh_env+=" CCB_PATCHSET=\"$CCB_PATCHSET\""
[ -n "$THT_PATCHSET" ] && ssh_env+=" THT_PATCHSET=\"$THT_PATCHSET\""
[ -n "$TPP_PATCHSET" ] && ssh_env+=" TPP_PATCHSET=\"$TPP_PATCHSET\""
[ -n "$PP_PATCHSET" ] && ssh_env+=" PP_PATCHSET=\"$PP_PATCHSET\""

if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  if [[ "$RHEL_CERT_TEST" == 'true' ]] ; then
    export RHEL_ACCOUNT_FILE=${RHEL_ACCOUNT_FILE:-'/home/root/rhel/rhel-account-cert'}
  else
    export RHEL_ACCOUNT_FILE=${RHEL_ACCOUNT_FILE:-'/home/root/rhel/rhel-account'}
  fi
  ssh_env+=" RHEL_ACCOUNT_FILE=$RHEL_ACCOUNT_FILE"
fi

echo "INFO: creating environment $(date)"
"$my_dir"/create_env.sh
echo "INFO: installing undercloud $(date)"
"$my_dir"/undercloud-install.sh

if [[ "$CLEAN_ENV" == 'create_vms_only' ]]  ; then
  echo "INFO: CLEAN_ENV=$CLEAN_ENV, finishing."
  trap - ERR
  exit 0
fi

echo "INFO: installing overcloud $(date)"
oc=1
ssh -T $ssh_opts $ssh_addr "sudo -u stack $ssh_env /home/stack/overcloud-install.sh"

echo "INFO: checking overcloud $(date)"
if [[ -n "$check_script" ]] ; then
  $check_script $ssh_addr "$ssh_opts"
else
  echo "WARNING: Deployment will not be checked!"
fi

trap - ERR

save_overcloud_logs
