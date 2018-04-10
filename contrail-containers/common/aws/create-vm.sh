#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

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
aws ${AWS_FLAGS} ec2 wait vpc-available --vpc-id $vpc_id

aws ${AWS_FLAGS} ec2 modify-vpc-attribute --vpc-id $vpc_id --enable-dns-hostnames
aws ${AWS_FLAGS} ec2 modify-vpc-attribute --vpc-id $vpc_id --enable-dns-support

cmd="aws ${AWS_FLAGS} ec2 create-subnet --vpc-id $vpc_id --cidr-block $VM_CIDR"
subnet_id=$(get_value_from_json "$cmd" ".Subnet.SubnetId")
echo "INFO: SUBNET_ID: $subnet_id"
echo "subnet_id=$subnet_id" >> $ENV_FILE
az=$(aws ${AWS_FLAGS} ec2 describe-subnets --subnet-id $subnet_id --query 'Subnets[*].AvailabilityZone' --output text)
echo "INFO: Availability zone for current deployment: $az"
echo "az=$az" >> $ENV_FILE
sleep 2
cmd="aws ${AWS_FLAGS} ec2 create-subnet --vpc-id $vpc_id --cidr-block $VM_CIDR_EXT --availability-zone $az"
subnet_ext_id=$(get_value_from_json "$cmd" ".Subnet.SubnetId")
echo "INFO: SUBNET_EXT_ID: $subnet_ext_id"
echo "subnet_ext_id=$subnet_ext_id" >> $ENV_FILE
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
aws ${AWS_FLAGS} ec2 authorize-security-group-ingress --group-id $group_id --cidr 0.0.0.0/0 --protocol tcp --port 4990
# contrail ports
for port in 8180 8143 80 6080 ; do
  aws ${AWS_FLAGS} ec2 authorize-security-group-ingress --group-id $group_id --cidr 0.0.0.0/0 --protocol tcp --port $port
done

key_name="testkey-$(cat /dev/urandom | tr -cd 'a-f0-9' | head -c 8)"
echo "key_name=$key_name" >> $ENV_FILE
key_result=$(aws ${AWS_FLAGS} ec2 create-key-pair --key-name $key_name)

kp=$(get_value_from_json "echo $key_result" ".KeyMaterial")
echo $kp | sed 's/\\n/\'$'\n''/g' > "$WORKSPACE/kp"
chmod 600 kp

function run_instance() {
  local type=$1
  local env_var_suffix=$2

  # it means that additional disks must be created for VM
  local bdm='{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":60,"DeleteOnTermination":true}},{"DeviceName":"/dev/xvdf","Ebs":{"VolumeSize":60,"DeleteOnTermination":true}}'
  local cmd=$(aws ${AWS_FLAGS} ec2 run-instances --image-id $IMAGE_ID --key-name $key_name --instance-type $type --subnet-id $subnet_id --associate-public-ip-address --block-device-mappings "[${bdm}]")
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

  local ssh="ssh -i $WORKSPACE/kp $SSH_OPTS $SSH_USER@$public_ip"
  echo "INFO: waiting for instance SSH"
  while ! $ssh uname -a 2>/dev/null ; do
    echo "WARNING: Machine isn't accessible yet"
    sleep 2
  done

  if [[ "$ENVIRONMENT_OS" == 'centos' ]]; then
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

  echo "INFO: Configure additional interface for cloud VM"
  eni_id=`aws ${AWS_FLAGS} ec2 create-network-interface --subnet-id $subnet_ext_id --query 'NetworkInterface.NetworkInterfaceId' --output text`
  eni_attach_id=`aws ${AWS_FLAGS} ec2 attach-network-interface --network-interface-id $eni_id --instance-id $instance_id --device-index 1 --query 'AttachmentId' --output text`
  aws ${AWS_FLAGS} ec2 modify-network-interface-attribute --network-interface-id $eni_id --attachment AttachmentId=$eni_attach_id,DeleteOnTermination=true
  echo "INFO: additional interface $eni_id is attached: $eni_attach_id"
  sleep 20
  create_iface $IF2 $ssh
  $ssh "$IFCONFIG_PATH/ifconfig" 2>/dev/null | grep -A 1 "^[a-z].*" | grep -v "\-\-"

  echo "INFO: Update packages on machine and install additional packages $(date)"
  if [[ "$ENVIRONMENT_OS" == 'centos' ]]; then
    $ssh "sudo yum install -y epel-release" &>>yum.log
    $ssh "sudo yum install -y mc git wget ntp ntpdate iptables iproute libxml2-utils python2.7" &>>yum.log
    $ssh "sudo systemctl disable chronyd.service && sudo systemctl enable ntpd.service && sudo systemctl start ntpd.service"
  elif [[ "$ENVIRONMENT_OS" == 'ubuntu' ]]; then
    $ssh "sudo apt-get -y update" &>>$HOME/apt.log
    $ssh 'DEBIAN_FRONTEND=noninteractive sudo -E apt-get -fy -o Dpkg::Options::="--force-confnew" upgrade' &>>$HOME/apt.log
    $ssh "sudo apt-get install -y --no-install-recommends mc git wget ntp ntpdate libxml2-utils python2.7" &>>$HOME/apt.log
  fi
}

for (( i=0; i<${CONT_NODES}; ++i )); do
  run_instance $CONT_NODE_TYPE cont_$i
done
for (( i=0; i<${COMP_NODES}; ++i )); do
  run_instance $COMP_NODE_TYPE comp_$i
done

ips_cont=(`grep public_ip_cont $ENV_FILE | cut -d '=' -f 2`)
ips_comp=(`grep public_ip_comp $ENV_FILE | cut -d '=' -f 2`)
ips=( ${ips_cont[@]} ${ips_comp[@]} )
master_ip=${ips_cont[0]}

cat <<EOF >>$ENV_FILE
master_ip=$master_ip
nodes_ips="${ips[@]}"
nodes_cont_ips="${ips_cont[@]}"
nodes_comp_ips="${ips_comp[@]}"
EOF

cat $ENV_FILE

trap - ERR EXIT

echo "INFO: Environment ready"
