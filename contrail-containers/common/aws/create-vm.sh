#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

NET_COUNT=${NET_COUNT:-1}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30"
ENV_FILE="$WORKSPACE/cloudrc"

trap 'catch_errors_cvm $LINENO' ERR EXIT
function catch_errors_cvm() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

source "$my_dir/definitions"
source "$my_dir/${ENVIRONMENT_OS}"

echo "INFO: Image ID: $IMAGE_ID"

function get_value_from_json() {
  local cmd_out=$($1 | jq $2)
  eval "echo $cmd_out"
}


if [ -f $ENV_FILE ]; then
  echo "ERROR: Previous environment found. Please check and cleanup."
  exit 1
fi

touch $ENV_FILE
echo "AWS_FLAGS='${AWS_FLAGS}'" >> $ENV_FILE
echo "SSH_USER='${SSH_USER}'" >> $ENV_FILE
echo "INFO: -------------------------------------------------------------------------- $(date)"

cmd="aws ${AWS_FLAGS} ec2 create-vpc --cidr-block $VPC_CIDR"
vpc_id=$(get_value_from_json "$cmd" ".Vpc.VpcId")
echo "INFO: VPC_ID: $vpc_id"
echo "vpc_id=$vpc_id" >> $ENV_FILE
sleep 10
aws ${AWS_FLAGS} ec2 wait vpc-available --vpc-id $vpc_id

aws ${AWS_FLAGS} ec2 modify-vpc-attribute --vpc-id $vpc_id --enable-dns-hostnames
aws ${AWS_FLAGS} ec2 modify-vpc-attribute --vpc-id $vpc_id --enable-dns-support

cmd="aws ${AWS_FLAGS} ec2 create-subnet --vpc-id $vpc_id --cidr-block ${VM_NET_PREFIX}.0/24"
subnet_id=$(get_value_from_json "$cmd" ".Subnet.SubnetId")
echo "INFO: SUBNET_ID: $subnet_id"
echo "subnet_id=$subnet_id" >> $ENV_FILE
az=$(aws ${AWS_FLAGS} ec2 describe-subnets --subnet-id $subnet_id --query 'Subnets[*].AvailabilityZone' --output text)
echo "INFO: Availability zone for current deployment: $az"
echo "az=$az" >> $ENV_FILE
sleep 2

declare -a subnet_ids
for ((net=1; net<NET_COUNT; ++net)); do
  cidr_name="VM_NET_PREFIX_${net}"
  cmd="aws ${AWS_FLAGS} ec2 create-subnet --vpc-id $vpc_id --cidr-block ${!cidr_name}.0/24 --availability-zone $az"
  subnet_id_next=$(get_value_from_json "$cmd" ".Subnet.SubnetId")
  echo "INFO: SUBNET_ID_$net: $subnet_id_next"
  echo "subnet_id_$net=$subnet_id_next" >> $ENV_FILE
  subnet_ids=( ${subnet_ids[@]} $subnet_id_next )
done

sleep 2
cmd="aws ${AWS_FLAGS} ec2 create-internet-gateway"
igw_id=$(get_value_from_json "$cmd" ".InternetGateway.InternetGatewayId")
echo "INFO: IGW_ID: $igw_id"
echo "igw_id=$igw_id" >> $ENV_FILE

aws ${AWS_FLAGS} ec2 attach-internet-gateway --internet-gateway-id $igw_id --vpc-id $vpc_id

cmd="aws ${AWS_FLAGS} ec2 describe-route-tables --filters Name=vpc-id,Values=$vpc_id"
rtb_id=$(get_value_from_json "$cmd" ".RouteTables[0].RouteTableId")
echo "INFO: RTB_ID: $rtb_id"

aws ${AWS_FLAGS} ec2 create-route --route-table-id $rtb_id --destination-cidr-block "0.0.0.0/0" --gateway-id $igw_id

# here should be only one 'default' group
group_id=$(aws ${AWS_FLAGS} ec2 describe-security-groups --filters Name=vpc-id,Values=$vpc_id --query 'SecurityGroups[*].GroupId' --output text)
echo "INFO: Group ID: $group_id"
# ssh port
aws ${AWS_FLAGS} ec2 authorize-security-group-ingress --group-id $group_id --cidr 0.0.0.0/0 --protocol tcp --port 22
# docker port
aws ${AWS_FLAGS} ec2 authorize-security-group-ingress --group-id $group_id --cidr 0.0.0.0/0 --protocol tcp --port 5000
# contrail ports
for port in 8180 8143 80 6080 ; do
  aws ${AWS_FLAGS} ec2 authorize-security-group-ingress --group-id $group_id --cidr 0.0.0.0/0 --protocol tcp --port $port
done

function run_instance() {
  local type=$1
  local env_var_suffix=$2
  local cloud_vm=$3

  # it means that additional disks must be created for VM
  local bdm='{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":60,"DeleteOnTermination":true}},{"DeviceName":"/dev/xvdf","Ebs":{"VolumeSize":60,"DeleteOnTermination":true}}'
  local cmd=$(aws ${AWS_FLAGS} ec2 run-instances --image-id $IMAGE_ID --key-name $KEY_NAME --instance-type $type --subnet-id $subnet_id --associate-public-ip-address --block-device-mappings "[${bdm}]")
  local instance_id=$(get_value_from_json "echo $cmd" ".Instances[0].InstanceId")
  echo "INFO: $env_var_suffix INSTANCE_ID: $instance_id"
  echo "instance_id_${env_var_suffix}=$instance_id" >> $ENV_FILE

  time aws ${AWS_FLAGS} ec2 wait instance-running --instance-ids $instance_id
  echo "INFO: $env_var_suffix instance ready."

  local cmd_result=$(aws ${AWS_FLAGS} ec2 describe-instances --instance-ids $instance_id)
  local public_ip=$(get_value_from_json "echo $cmd_result" ".Reservations[0].Instances[0].PublicIpAddress")
  echo "INFO: $env_var_suffix public IP: $public_ip"
  echo "public_ip_${env_var_suffix}=$public_ip" >> $ENV_FILE

  # inner communication...
  aws ${AWS_FLAGS} ec2 authorize-security-group-ingress --group-id $group_id --cidr $public_ip/32 --protocol tcp --port 0-65535

  local ssh="ssh -i $HOME/.ssh/id_rsa $SSH_OPTS $SSH_USER@$public_ip"
  echo "INFO: waiting for instance SSH"
  while ! $ssh uname -a 2>/dev/null ; do
    echo "WARNING: Machine isn't accessible yet"
    sleep 2
  done

  if [[ "$cloud_vm" == 'true' ]] && ((NET_COUNT > 1)) ; then
    echo "INFO: Configure additional interfaces for cloud VM"
    for ((i=1; i<NET_COUNT; ++i)); do
      sid=${subnet_ids[i-1]}
      eni_id=`aws ${AWS_FLAGS} ec2 create-network-interface --subnet-id $sid --query 'NetworkInterface.NetworkInterfaceId' --output text`
      eni_attach_id=`aws ${AWS_FLAGS} ec2 attach-network-interface --network-interface-id $eni_id --instance-id $instance_id --device-index $i --query 'AttachmentId' --output text`
      aws ${AWS_FLAGS} ec2 modify-network-interface-attribute --network-interface-id $eni_id --attachment AttachmentId=$eni_attach_id,DeleteOnTermination=true
      echo "INFO: additional interface $eni_id is attached: $eni_attach_id"
    done
  fi

  if [[ "$ENVIRONMENT_OS" == 'centos' && $cloud_vm == 'true' ]]; then
    # there are some cases when AWS image has strange kernel version and vrouter can't be loaded
    $ssh "sudo yum -y update"
    $ssh "sudo reboot" || /bin/true
    echo "INFO: reboot & waiting for instance SSH"
    while ! $ssh uname -a 2>/dev/null ; do
      echo "WARNING: Machine isn't accessible yet"
      sleep 2
    done
  fi

  echo "INFO: Configure additional disk for cloud VM"
  $ssh "(echo o; echo n; echo p; echo 1; echo ; echo ; echo w) | sudo fdisk /dev/xvdf"
  $ssh "sudo mkfs.ext4 /dev/xvdf1 ; sudo mkdir -p /var/lib/docker ; sudo su -c \"echo '/dev/xvdf1  /var/lib/docker  auto  defaults,auto  0  0' >> /etc/fstab\" ; sudo mount /var/lib/docker"

  if [[ "$cloud_vm" != 'true' ]]; then
    return
  fi

  sleep 20
  local net
  for ((net=1; net<NET_COUNT; ++net)); do
    var="IF$((net+1))"
    create_iface ${!var} $ssh
  done
  $ssh "$IFCONFIG_PATH/ifconfig" 2>/dev/null | grep -A 1 "^[a-z].*" | grep -v "\-\-"

  echo "INFO: Update packages on machine and install additional packages $(date)"
  if [[ "$ENVIRONMENT_OS" == 'centos' ]]; then
    $ssh "sudo yum install -y epel-release" &>>yum.log
    $ssh "sudo yum install -y mc git wget iptables iproute libxml2-utils python2.7 lsof python-pip python-devel gcc" &>>yum.log
    $ssh "sudo yum remove -y python-requests PyYAML" &>>yum.log
  elif [[ "$ENVIRONMENT_OS" == 'ubuntu16' || "$ENVIRONMENT_OS" == 'ubuntu18' ]]; then
    $ssh "sudo apt-get -y update" &>>$HOME/apt.log
    $ssh 'DEBIAN_FRONTEND=noninteractive sudo -E apt-get -fy -o Dpkg::Options::="--force-confnew" upgrade' &>>$HOME/apt.log
    $ssh "sudo apt-get install -y --no-install-recommends mc git wget ntp ntpdate libxml2-utils python2.7 lsof python-pip python-dev gcc" &>>$HOME/apt.log
  fi
  $ssh "pip install pip --upgrade && hash -r && pip install setuptools requests" &>>$HOME/pip.log
}

if [[ "$CONTAINER_REGISTRY" == 'build' || "$CONTAINER_REGISTRY" == 'fullbuild' ]]; then
  run_instance $BUILD_NODE_TYPE build 'false'
  build_ip=`grep public_ip_build $ENV_FILE | cut -d '=' -f 2`
fi
for (( i=0; i<${CONT_NODES}; ++i )); do
  run_instance $CONT_NODE_TYPE cont_$i 'true'
done
for (( i=0; i<${COMP_NODES}; ++i )); do
  run_instance $COMP_NODE_TYPE comp_$i 'true'
done

ips_cont=(`grep public_ip_cont $ENV_FILE | cut -d '=' -f 2`)
ips_comp=(`grep public_ip_comp $ENV_FILE | cut -d '=' -f 2`)
ips=( ${ips_cont[@]} ${ips_comp[@]} )
master_ip=${ips_cont[0]}

cat <<EOF >>$ENV_FILE
ssh_key_file=$HOME/.ssh/id_rsa
build_ip=$build_ip
master_ip=$master_ip
nodes_ips="${ips[@]}"
nodes_cont_ips="${ips_cont[@]}"
nodes_comp_ips="${ips_comp[@]}"
nodes_net=${VM_NET_PREFIX}.0/24
nodes_gw=${VM_NET_PREFIX}.1
nodes_vip=${VM_NET_PREFIX}.254
EOF

for ((net=1; net<NET_COUNT; ++net)) ; do
  ips=( )
  cont_ips=( )
  comp_ips=( )
  var="IF$((net+1))"
  iface=${!var}
  for ip in ${ips_cont[@]} ; do
    ip=`ssh -i $HOME/.ssh/id_rsa $SSH_OPTS $SSH_USER@$ip ip addr show dev $iface 2>/dev/null | awk '/inet /{print $2}' | cut -d '/' -f 1`
    ips=( ${ips[@]} $ip )
    cont_ips=( ${cont_ips[@]} $ip )
  done
  for ip in ${ips_comp[@]} ; do
    ip=`ssh -i $HOME/.ssh/id_rsa $SSH_OPTS $SSH_USER@$ip ip addr show dev $iface 2>/dev/null | awk '/inet /{print $2}' | cut -d '/' -f 1`
    ips=( ${ips[@]} $ip )
    comp_ips=( ${comp_ips[@]} $ip )
  done
  prefix_name="VM_NET_PREFIX_${net}"
  cat <<EOF >>$ENV_FILE
nodes_ips_${net}="${ips[@]}"
nodes_cont_ips_${net}="${cont_ips[@]}"
nodes_comp_ips_${net}="${comp_ips[@]}"
nodes_net_${net}=${!prefix_name}.0/24
nodes_gw_${net}=${!prefix_name}.1
nodes_vip_${net}=${!prefix_name}.254
EOF
done

cat $ENV_FILE

trap - ERR EXIT

echo "INFO: Environment ready"
