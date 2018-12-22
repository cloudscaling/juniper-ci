#!/bin/bash

ENV_FILE="$WORKSPACE/cloudrc"

if [ ! -f $ENV_FILE ]; then
  echo "ERROR: There is no environment file. There is nothing to clean up."
  exit 1
fi

source $ENV_FILE

errors="0"

for iid in `grep 'instance_id_' $ENV_FILE | cut -d '=' -f 2` ; do
  if aws ${AWS_FLAGS} ec2 terminate-instances --instance-ids $iid ; then
    echo "INFO: instance $iid has been terminated."
  else
    errors=1
  fi
done
for iid in `grep 'instance_id_' $ENV_FILE | cut -d '=' -f 2` ; do
  aws ${AWS_FLAGS} ec2 wait instance-terminated --instance-ids $iid
done

aws ${AWS_FLAGS} ec2 detach-internet-gateway --internet-gateway-id $igw_id --vpc-id $vpc_id
[[ $? == 0 ]] || errors="1"
aws ${AWS_FLAGS} ec2 delete-internet-gateway --internet-gateway-id $igw_id
[[ $? == 0 ]] || errors="1"

aws ${AWS_FLAGS} ec2 delete-subnet --subnet-id $subnet_id
[[ $? == 0 ]] || errors="1"
sleep 2

for iid in `grep 'subnet_id_' $ENV_FILE | cut -d '=' -f 2` ; do
  aws ${AWS_FLAGS} ec2 delete-subnet --subnet-id $iid
  [[ $? == 0 ]] || errors="1"
done
sleep 2

aws ${AWS_FLAGS} ec2 delete-vpc --vpc-id $vpc_id
[[ $? == 0 ]] || errors="1"

if [ $errors == "0" ]; then
  rm $ENV_FILE
else
  mv $ENV_FILE $ENV_FILE.$BUILD_ID
fi
