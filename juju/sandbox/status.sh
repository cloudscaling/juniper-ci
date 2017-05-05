#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

$my_dir/_set-juju-creds.sh &>/dev/null

if ! juju status &>/dev/null ; then
  echo "-1"
  exit
fi

all_units=`juju status --format oneline | grep "workload:" | wc -l`
ready_units=`juju status --format line | grep "workload:active" | wc -l`
if (( ready_units < all_units )) ; then
  echo $(( ready_units * 100 / all_units ))
  exit
fi

echo "100"

ip=`juju status --format line | awk '/ openstack-dashboard/{print $3}'`
echo "http://$ip/horizon"

ip=`juju status --format line | awk '/ contrail-controller/{print $3}'`
echo "http://$ip:8080/"

ip=`juju status --format line | awk '/ contrail-controller/{print $3}'`
echo "http://$ip:5000/"
