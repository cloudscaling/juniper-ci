#!/bin/bash

ENV_FILE="cloudrc"

if [ ! -f $ENV_FILE ]; then
  "There is no environment file. There is nothing to clean up."
  exit 1
fi

source $ENV_FILE

errors="0"

aws ec2 terminate-instances --instance-ids $instance_id
[[ $? == 0 ]] || errors="1"
if [[ $? == 0 ]]; then
  time aws ec2 wait instance-terminated --instance-ids $instance_id
  echo "Instance terminated."
fi

rm kp
aws ec2 delete-key-pair --key-name $key_name
[[ $? == 0 ]] || errors="1"

aws ec2 detach-internet-gateway --internet-gateway-id $igw_id --vpc-id $vpc_id
[[ $? == 0 ]] || errors="1"
aws ec2 delete-internet-gateway --internet-gateway-id $igw_id
[[ $? == 0 ]] || errors="1"

aws ec2 delete-subnet --subnet-id $subnet_id
[[ $? == 0 ]] || errors="1"
sleep 2
aws ec2 delete-vpc --vpc-id $vpc_id
[[ $? == 0 ]] || errors="1"

if [ $errors == "0" ]; then
  rm $ENV_FILE
fi
