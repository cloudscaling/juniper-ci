#!/bin/bash

ENV_FILE="$WORKSPACE/cloudrc"

if [ ! -f $ENV_FILE ]; then
  echo "ERROR: There is no environment file. There is nothing to clean up."
  exit 1
fi

source $ENV_FILE

errors="0"

if [[ -n "$instance_id_cloud" ]] ; then
  aws ${AWS_FLAGS} ec2 terminate-instances --instance-ids $instance_id_cloud
  [[ $? == 0 ]] || errors="1"
  if [[ $? == 0 ]]; then
    aws ${AWS_FLAGS} ec2 wait instance-terminated --instance-ids $instance_id_cloud
    echo "INFO: Cloud instance terminated."
  fi
fi

if [[ -n "$instance_id_build" ]] ; then
  aws ${AWS_FLAGS} ec2 terminate-instances --instance-ids $instance_id_build
  [[ $? == 0 ]] || errors="1"
  if [[ $? == 0 ]]; then
    aws ${AWS_FLAGS} ec2 wait instance-terminated --instance-ids $instance_id_build
    echo "INFO: Build instance terminated."
  fi
fi

if [[ -f "$WORKSPACE/kp" ]] ; then
  rm "$WORKSPACE/kp"
  aws ${AWS_FLAGS} ec2 delete-key-pair --key-name $key_name
  [[ $? == 0 ]] || errors="1"
fi

aws ${AWS_FLAGS} ec2 detach-internet-gateway --internet-gateway-id $igw_id --vpc-id $vpc_id
[[ $? == 0 ]] || errors="1"
aws ${AWS_FLAGS} ec2 delete-internet-gateway --internet-gateway-id $igw_id
[[ $? == 0 ]] || errors="1"

aws ${AWS_FLAGS} ec2 delete-subnet --subnet-id $subnet_id
[[ $? == 0 ]] || errors="1"
sleep 2
aws ${AWS_FLAGS} ec2 delete-subnet --subnet-id $subnet_ext_id
[[ $? == 0 ]] || errors="1"
sleep 2
aws ${AWS_FLAGS} ec2 delete-vpc --vpc-id $vpc_id
[[ $? == 0 ]] || errors="1"

if [ $errors == "0" ]; then
  rm $ENV_FILE
else
  mv $ENV_FILE $ENV_FILE.$BUILD_ID
fi
