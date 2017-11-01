#!/bin/bash -e

ENV_FILE="$WORKSPACE/cloudrc"
VM_CIDR="192.168.130.0/24"
# ubuntu/images/hvm-ssd/ubuntu-trusty-14.04-amd64-server-20150325
# us-east-1 IMAGE_ID="ami-d05e75b8"
# ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-201704
IMAGE_ID="${1:-ami-618fab04}"
VM_TYPE="${2:-c3.xlarge}"

function get_value_from_json() {
  local cmd_out=$($1 | jq $2)
  eval "echo $cmd_out"
}


if [ -f $ENV_FILE ]; then
  echo "ERROR: Previous environment found. Please check and cleanup."
  exit 1
fi

touch $ENV_FILE
echo "INFO: -------------------------------------------------------------------------- $(date)"

cmd="aws ec2 create-vpc --cidr-block $VM_CIDR"
vpc_id=$(get_value_from_json "$cmd" ".Vpc.VpcId")
echo "INFO: VPC_ID: $vpc_id"
echo "vpc_id=$vpc_id" >> $ENV_FILE

cmd="aws ec2 create-subnet --vpc-id $vpc_id --cidr-block $VM_CIDR"
subnet_id=$(get_value_from_json "$cmd" ".Subnet.SubnetId")
echo "INFO: SUBNET_ID: $subnet_id"
echo "subnet_id=$subnet_id" >> $ENV_FILE
sleep 2

cmd="aws ec2 create-internet-gateway"
igw_id=$(get_value_from_json "$cmd" ".InternetGateway.InternetGatewayId")
echo "INFO: IGW_ID: $igw_id"
echo "igw_id=$igw_id" >> $ENV_FILE

aws ec2 attach-internet-gateway --internet-gateway-id $igw_id --vpc-id $vpc_id

cmd="aws ec2 describe-route-tables --filters Name=vpc-id,Values=$vpc_id"
rtb_id=$(get_value_from_json "$cmd" ".RouteTables[0].RouteTableId")
echo "INFO: RTB_ID: $rtb_id"

aws ec2 create-route --route-table-id $rtb_id --destination-cidr-block "0.0.0.0/0" --gateway-id $igw_id

key_name="testkey-$(cat /dev/urandom | tr -cd 'a-f0-9' | head -c 8)"
echo "key_name=$key_name" >> $ENV_FILE
key_result=$(aws ec2 create-key-pair --key-name $key_name)

kp=$(get_value_from_json "echo $key_result" ".KeyMaterial")
echo $kp | sed 's/\\n/\'$'\n''/g' > "$WORKSPACE/kp"
chmod 600 kp


cmd=$(aws ec2 run-instances --image-id $IMAGE_ID --key-name $key_name --instance-type $VM_TYPE --block-device-mappings '[{"DeviceName":"/dev/sdh","Ebs":{"VolumeSize":20,"DeleteOnTermination":true}}]' --subnet-id $subnet_id --associate-public-ip-address)
instance_id=$(get_value_from_json "echo $cmd" ".Instances[0].InstanceId")
echo "INFO: INSTANCE_ID: $instance_id"
echo "instance_id=$instance_id" >> $ENV_FILE

time aws ec2 wait instance-running --instance-ids $instance_id
echo "INFO: Instance ready."

cmd_result=$(aws ec2 describe-instances --instance-ids $instance_id)
public_ip=$(get_value_from_json "echo $cmd_result" ".Reservations[0].Instances[0].PublicIpAddress")
echo "INFO: Public IP: $public_ip"
echo "public_ip=$public_ip" >> $ENV_FILE
group_id=$(get_value_from_json "echo $cmd_result" ".Reservations[0].Instances[0].SecurityGroups[0].GroupId")
echo "INFO: Group ID: $group_id"

aws ec2 authorize-security-group-ingress --group-id $group_id --cidr 0.0.0.0/0 --protocol tcp --port 22
aws ec2 authorize-security-group-ingress --group-id $group_id --cidr $public_ip/32 --protocol tcp --port 0-65535

for port in 8774 8776 8788 5000 9696 8080 9292 35357 ; do
  aws ec2 authorize-security-group-ingress --group-id $group_id --cidr 0.0.0.0/0 --protocol tcp --port $port
done

echo "INFO: Environment ready"
