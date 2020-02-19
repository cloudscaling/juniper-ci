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

# check if environment is present
if $virsh_cmd list --all | grep -q "${job_prefix}-cont" ; then
  echo 'ERROR: environment present. please clean up first'
  $virsh_cmd list --all | grep "${job_prefix}-"
  exit 1
fi

create_network $nname $addr
create_network $nname_vm $addr_vm

# create pool
$virsh_cmd pool-info $poolname &> /dev/null || create_pool $poolname
pool_path=$(get_pool_path $poolname)

function run_machine() {
  local name="$1"
  local cpu="$2"
  local ram="$3"
  local mac_suffix="$4"
  local ip=$5
  # optional params
  local ip_vm=$6

  if [[ $SERIES == 'xenial' ]] ; then
    local osv='ubuntu16.04'
  elif [[ $SERIES == 'bionic' ]] ; then
    # 18.04 is not in osinfo db yet. https://bugs.launchpad.net/ubuntu/+source/virt-manager/+bug/1770206
    local osv='ubuntu16.04'
  else
    local osv='ubuntu14.04'
  fi

  local params=""
  if [[ -n "$ip_vm" ]] ; then
    params="$params --network network=$nname_vm,model=$net_driver,mac=$mac_base_vm:$mac_suffix"
  fi

  echo "INFO: running  machine $name $(date)"
  cp $base_image $pool_path/$name.qcow2
  virt-install --name $name \
    --ram $ram \
    --vcpus $cpu \
    --memorybacking hugepages=on \
    --virt-type kvm \
    --os-type=linux \
    --os-variant $osv \
    --disk path=$pool_path/$name.qcow2,cache=writeback,bus=virtio,serial=$(uuidgen) \
    --noautoconsole \
    --graphics vnc,listen=0.0.0.0 \
    --network network=$nname,model=$net_driver,mac=$mac_base:$mac_suffix \
    --cpu host \
    --boot hd \
    $params \
    --dry-run --print-xml > /tmp/oc-$name.xml
  virsh define --file /tmp/oc-$name.xml
  virsh net-update $nname add ip-dhcp-host "<host mac='$mac_base:$mac_suffix' name='$name' ip='$ip' />"
  if [[ -n "$ip_vm" ]] ; then
    virsh net-update $nname_vm add ip-dhcp-host "<host mac='$mac_base_vm:$mac_suffix' name='$name-vm' ip='$ip_vm' />"
  fi
  virsh start $name --force-boot
  echo "INFO: machine $name run $(date)"
}

function wait_kvm_machine() {
  local dest=$1
  local wait_cmd=${2:-ssh}
  local iter=0
  sleep 10
  while ! $wait_cmd $dest "uname -a" &>/dev/null ; do
    ((++iter))
    if (( iter > 9 )) ; then
      echo "ERROR: machine $dest is not accessible $(date)"
      exit 2
    fi
    sleep 10
  done
}

juju_cont_ip="$addr.$juju_cont_idx"
run_machine ${job_prefix}-cont 1 2048 $juju_cont_idx $juju_cont_ip
wait_kvm_machine $image_user@$juju_cont_ip

echo "INFO: bootstraping juju controller $(date)"
juju bootstrap manual/$image_user@$juju_cont_ip $juju_controller_name

function run_cloud_machine() {
  local name=${job_prefix}-$1
  local mac_suffix=$2
  local mem=$3
  local ip=$4

  local ip="$addr.$mac_suffix"
  run_machine $name 4 $mem $mac_suffix $ip "$addr_vm.$mac_suffix"
  echo "INFO: start machine $name waiting $name $(date)"
  wait_kvm_machine $image_user@$ip
  echo "INFO: adding machine $name to juju controller $(date)"
  juju-add-machine ssh:$image_user@$ip
  mch=`get_machine_by_ip $ip`
  wait_kvm_machine $mch juju-ssh
  # apply hostname for machine
  juju-ssh $mch "sudo bash -c 'echo $name > /etc/hostname ; hostname $name'" 2>/dev/null
  # after first boot we must remove cloud-init
  juju-ssh $mch "sudo rm -rf /etc/systemd/system/cloud-init.target.wants /lib/systemd/system/cloud*"
  juju-ssh $mch "sudo apt-get -y purge unattended-upgrades" &>>$log_dir/apt.log
  juju-ssh $mch "sudo apt-get update" &>>$log_dir/apt.log
  juju-ssh $mch "DEBIAN_FRONTEND=noninteractive sudo -E apt-get -fy -o Dpkg::Options::='--force-confnew' upgrade" &>>$log_dir/apt.log
  juju-ssh $mch "sudo apt-get install -fy libxml2-utils mc wget jq" &>>$log_dir/apt.log

  echo "INFO: machine $name (juju machine: $mch) is ready $(date)"
}

function run_compute() {
  local index=$1
  local mac_var_name="comp_${index}_idx"
  local mac_suffix=${!mac_var_name}
  echo "INFO: creating compute $index (mac suffix $mac_suffix) $(date)"
  local ip="$addr.$mac_suffix"
  local ip2="$addr_vm.$mac_suffix"
  run_cloud_machine comp-$index $mac_suffix 8192 $ip
  mch=`get_machine_by_ip $ip`

  echo "INFO: preparing compute $index $(date)"
  juju-scp "$my_dir/files/__prepare-compute.sh" $mch:prepare-compute.sh 2>/dev/null
  juju-ssh $mch "sudo ./prepare-compute.sh $addr $ip2"
  juju-ssh $mch "sudo reboot" 2>/dev/null || /bin/true
  wait_kvm_machine $mch juju-ssh
}

function run_controller() {
  local index=$1
  local mem=$2
  local prepare_for_openstack=$3
  local mac_var_name="cont_${index}_idx"
  local mac_suffix=${!mac_var_name}
  echo "INFO: creating controller $index (mac suffix $mac_suffix) $(date)"
  local ip="$addr.$mac_suffix"
  run_cloud_machine cont-$index $mac_suffix $mem $ip
  mch=`get_machine_by_ip $ip`

  echo "INFO: preparing controller $index $(date)"
  juju-scp "$my_dir/files/__prepare-controller.sh" $mch:prepare-controller.sh 2>/dev/null
  juju-ssh $mch "sudo ./prepare-controller.sh $addr $prepare_for_openstack"
  juju-ssh $mch "sudo reboot" 2>/dev/null || /bin/true
  wait_kvm_machine $mch juju-ssh

  if [[ "$prepare_for_openstack" == '1' && "$SERIES" == 'trusty' ]]; then
    # NOTE: run juju processes to install/configure lxd and then reconfigure it again
    mch=$(get_machine_by_ip $ip)
    local lxd_mch=`juju-add-machine --series=$SERIES lxd:$mch 2>&1 | tail -1 | awk '{print $3}'`
    wait_for_machines $lxd_mch
    juju-remove-machine $lxd_mch
    juju-ssh $mch "sudo sed -i -e 's/^USE_LXD_BRIDGE.*$/USE_LXD_BRIDGE=\"false\"/m' /etc/default/lxd-bridge" 2>/dev/null
    juju-ssh $mch "sudo sed -i -e 's/^LXD_BRIDGE.*$/LXD_BRIDGE=\"br-$IF1\"/m' /etc/default/lxd-bridge" 2>/dev/null
    juju-ssh $mch "sudo reboot" 2>/dev/null || /bin/true
    wait_kvm_machine $mch juju-ssh
  fi

  juju-scp "$my_dir/files/lxd-default.yaml" $mch:lxd-default.yaml 2>/dev/null
  juju-ssh $mch "cat ./lxd-default.yaml | sudo lxc profile edit default"
}

for ((i=1; i<=comp_count; ++i)); do
  run_compute $i
done

case "$DEPLOY_MODE" in
  "one")
    run_controller 0 16384 1
    ;;
  "two")
    run_controller 0 8192 1
    run_controller 1 16384 0
    ;;
  "ha")
    run_controller 0 8192 1
    run_controller 1 16384 0
    run_controller 2 16384 0
    run_controller 3 16384 0
    ;;
  *)
    echo "ERROR: Invalid mode: $DEPLOY_MODE (must be 'one', 'two' or 'ha')"
    exit 1
    ;;
esac

wait_for_all_machines

if [[ ${ISSU_VM,,} == 'true' ]]; then
  echo "INFO: ISSU testing - deploy second controller"
  run_controller 7 16384 0
fi

echo "INFO: Environment created $(date)"

virsh net-dhcp-leases $nname

trap - ERR EXIT
