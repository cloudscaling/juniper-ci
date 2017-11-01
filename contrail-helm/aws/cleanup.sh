#!/bin/bash

ENV_FILE="$WORKSPACE/cloudrc"

if [ ! -f $ENV_FILE ]; then
  echo "ERROR: There is no environment file. There is nothing to clean up."
  exit 1
fi

source $ENV_FILE

errors="0"

if [[ -n "$instance_id" ]] ; then
  aws ec2 terminate-instances --instance-ids $instance_id
  [[ $? == 0 ]] || errors="1"
  if [[ $? == 0 ]]; then
    timeout -s 9 120 aws ec2 wait instance-terminated --instance-ids $instance_id
   echo "INFO: Instance terminated."
  fi
fi

if [[ -f "$WORKSPACE/kp" ]] ; then
  rm "$WORKSPACE/kp"
  aws ec2 delete-key-pair --key-name $key_name
  [[ $? == 0 ]] || errors="1"
fi

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
else
  mv $ENV_FILE $ENV_FILE.$BUILD_ID
fi
