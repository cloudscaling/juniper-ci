#!/bin/bash -e

./juniper-ci/juju/sandbox/_set-juju-creds.sh

juju destroy-controller  -y --destroy-all-models amazon

iid=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r ".instanceId"`
aws ec2 terminate-instances --instance-ids $iid
