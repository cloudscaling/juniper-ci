#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/functions"

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

  local params=""
  if echo "$name" | grep -q comp ; then
    params="--memorybacking hugepages=on"
  fi

  if [[ $SERIES == 'xenial' ]] ; then
    local osv='ubuntu16.04'
  else
    local osv='ubuntu14.04'
  fi

  if [[ -n "$ip_vm" ]] ; then
    params="$params --network network=$nname_vm,model=$net_driver,mac=$mac_base_vm:$mac_suffix"
  fi

  echo "INFO: running  machine $name $(date)"
  cp $BASE_IMAGE $pool_path/$name.qcow2
  virt-install --name $name \
    --ram $ram \
    --vcpus $cpu \
    --virt-type kvm \
    --os-type=linux \
    --os-variant $osv \
    --disk path=$pool_path/$name.qcow2,cache=writeback,bus=virtio,serial=$(uuidgen) \
    --noautoconsole \
    --graphics vnc,listen=0.0.0.0 \
    --network network=$nname,model=$net_driver,mac=$mac_base:$mac_suffix \
    --cpu SandyBridge,+vmx,+ssse3 \
    --boot hd \
    $params \
    --dry-run --print-xml > /tmp/oc-$name.xml
  virsh define --file /tmp/oc-$name.xml
  virsh net-update $nname add ip-dhcp-host "<host mac='$mac_base:$mac_suffix' name='$name' ip='$ip' />"
  if [[ -n "$ip_vm" ]] ; then
    virsh net-update $nname_vm add ip-dhcp-host "<host mac='$mac_base_vm:$mac_suffix' name='$name' ip='$ip_vm' />"
  fi
  virsh start $name --force-boot
  echo "INFO: machine $name run $(date)"
}

wait_cmd="ssh"
function wait_kvm_machine() {
  local ip=$1
  local iter=0
  sleep 10
  while ! $wait_cmd $image_user@$ip "uname -a" &>/dev/null ; do
    ((++iter))
    if (( iter > 9 )) ; then
      echo "ERROR: machine $ip is not accessible $(date)"
      exit 2
    fi
    sleep 10
  done
}

cont_ip="$addr.$cont_idx"
run_machine ${job_prefix}-cont 1 2048 $cont_idx $cont_ip
wait_kvm_machine $cont_ip

echo "INFO: bootstraping juju controller $(date)"
juju bootstrap manual/$image_user@$cont_ip $juju_controller_name

declare -A machines

function run_cloud_machine() {
  local name=$1
  local mac_suffix=$2
  local mem=$3
  local ip=$4

  local ip="$addr.$mac_suffix"
  run_machine ${job_prefix}-os-$name 4 $mem $mac_suffix $ip "$addr_vm.$mac_suffix"
  machines["$name"]=$ip
  echo "INFO: start machine $name waiting $name $(date)"
  wait_kvm_machine $ip
  echo "INFO: adding machine $name to juju controller $(date)"
  juju-add-machine ssh:$image_user@$ip
  echo "INFO: machine $name is ready $(date)"
}

function run_compute() {
  local index=$1
  local mac_var_name="os_comp_${index}_idx"
  local mac_suffix=${!mac_var_name}
  echo "INFO: creating compute $index (mac suffix $mac_suffix) $(date)"
  local ip="$addr.$mac_suffix"
  run_cloud_machine comp-$index $mac_suffix 4096 $ip

  echo "INFO: preparing compute $index $(date)"
  kernel_version=`juju-ssh $image_user@$ip uname -r 2>/dev/null | tr -d '\r'`
  if [[ "$SERIES" == 'trusty' ]]; then
    juju-ssh $image_user@$ip "sudo add-apt-repository -y cloud-archive:mitaka ; sudo apt-get update" &>>$log_dir/apt.log
  fi
  juju-ssh $image_user@$ip "sudo apt-get -fy install linux-image-extra-$kernel_version dpdk mc wget apparmor-profiles" &>>$log_dir/apt.log
  juju-scp "$my_dir/files/50-cloud-init-compute-$SERIES.cfg" $image_user@$ip:50-cloud-init.cfg 2>/dev/null
  juju-ssh $image_user@$ip "sudo cp ./50-cloud-init.cfg /etc/network/interfaces.d/50-cloud-init.cfg" 2>/dev/null
  if [[ "$SERIES" == 'trusty' ]]; then
    # '50-cloud-init.cfg' is default name for xenial and it is overwritten
    juju-ssh $image_user@$ip "sudo rm /etc/network/interfaces.d/eth0.cfg" 2>/dev/null
  fi
  juju-ssh $image_user@$ip "echo 'supersede routers $addr.1;' | sudo tee -a /etc/dhcp/dhclient.conf"
  juju-ssh $image_user@$ip "sudo reboot" 2>/dev/null || /bin/true
  wait_kvm_machine $ip
}

function run_controller() {
  local index=$1
  local mem=$2
  local prepare_for_openstack=$3
  local mac_var_name="os_cont_${index}_idx"
  local mac_suffix=${!mac_var_name}
  echo "INFO: creating controller $index (mac suffix $mac_suffix) $(date)"
  local ip="$addr.$mac_suffix"
  run_cloud_machine cont-$index $mac_suffix $mem $ip

  echo "INFO: preparing controller $index $(date)"
  juju-ssh $image_user@$ip "sudo apt-get -fy install mc wget bridge-utils" &>>$log_dir/apt.log
  if [[ "$prepare_for_openstack" == '1' ]]; then
    if [[ "$SERIES" == 'trusty' ]]; then
      juju-ssh $image_user@$ip "sudo add-apt-repository -y cloud-archive:mitaka ; sudo apt-get update ; sudo apt-get install -fy lxd" &>>$log_dir/apt.log
    fi
    juju-ssh $image_user@$ip "sudo sed -i -e 's/^USE_LXD_BRIDGE.*$/USE_LXD_BRIDGE=\"false\"/m' /etc/default/lxd-bridge" 2>/dev/null
    juju-ssh $image_user@$ip "sudo sed -i -e 's/^LXD_BRIDGE.*$/LXD_BRIDGE=\"br-$IF1\"/m' /etc/default/lxd-bridge" 2>/dev/null
  fi
  juju-scp "$my_dir/files/50-cloud-init-controller-$SERIES.cfg" $image_user@$ip:50-cloud-init.cfg 2>/dev/null
  juju-ssh $image_user@$ip "sudo cp ./50-cloud-init.cfg /etc/network/interfaces.d/50-cloud-init.cfg" 2>/dev/null
  if [[ "$SERIES" == 'trusty' ]]; then
    # '50-cloud-init.cfg' is default name for xenial and it is overwritten
    juju-ssh $image_user@$ip "sudo rm /etc/network/interfaces.d/eth0.cfg" 2>/dev/null
  fi
  juju-ssh $image_user@$ip "echo 'supersede routers $addr.1;' | sudo tee -a /etc/dhcp/dhclient.conf"
  juju-ssh $image_user@$ip "sudo reboot" 2>/dev/null || /bin/true
  wait_kvm_machine $ip

  if [[ "$prepare_for_openstack" == '1' && "$SERIES" == 'trusty' ]]; then
    # NOTE: run juju processes to install/configure lxd and then reconfigure it again
    mch=$(get_machine_by_ip $ip)
    local lxd_mch=`juju-add-machine --series=$SERIES lxd:$mch 2>&1 | tail -1 | awk '{print $3}'`
    wait_for_machines $lxd_mch
    juju-remove-machine $lxd_mch
    juju-ssh $image_user@$ip "sudo sed -i -e 's/^USE_LXD_BRIDGE.*$/USE_LXD_BRIDGE=\"false\"/m' /etc/default/lxd-bridge" 2>/dev/null
    juju-ssh $image_user@$ip "sudo sed -i -e 's/^LXD_BRIDGE.*$/LXD_BRIDGE=\"br-$IF1\"/m' /etc/default/lxd-bridge" 2>/dev/null
    juju-ssh $image_user@$ip "sudo reboot" 2>/dev/null || /bin/true
    wait_kvm_machine $ip
  fi
}

run_compute 1
run_compute 2

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

echo "INFO: creating hosts file $(date)"
truncate -s 0 $WORKSPACE/hosts
for m in ${!machines[@]} ; do
  echo "${machines[$m]}    $m" >> $WORKSPACE/hosts
done
cat $WORKSPACE/hosts
echo "INFO: Applying hosts file and hostnames $(date)"
for m in ${!machines[@]} ; do
  ip=${machines[$m]}
  echo "INFO: Apply $m for $ip"
  juju-scp $WORKSPACE/hosts $image_user@$ip:hosts
  juju-ssh $image_user@$ip "sudo bash -c 'echo $m > /etc/hostname ; hostname $m'" 2>/dev/null
  juju-ssh $image_user@$ip 'sudo bash -c "cat ./hosts >> /etc/hosts"' 2>/dev/null
done
rm $WORKSPACE/hosts

echo "INFO: Environment created $(date)"

virsh net-dhcp-leases $nname

trap - ERR EXIT
