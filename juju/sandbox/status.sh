#!/bin/bash -e

DEPLOY_PART_PERCENTAGE=25

if [[ "$HOME" == "" ]] ; then
  echo "ERROR: HOME variable must be set"
  exit 1
fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

pid=''
for ff in `ls $HOME/deploy_status.*` ; do
  pid=`echo $ff | cut -d '.' -f 2`
  if kill -0 $pid &>/dev/null ; then
    break
  fi
  pid=''
done

if [ -n "$pid" ] ; then
  stage=`cat $HOME/deploy_status.$pid | sed -n -e '1{p;q}'`
  stages_count=`cat $HOME/deploy_status.$pid | sed -n -e '2{p;q}'`
  status=`cat $HOME/deploy_status.$pid | sed -n -e '3{p;q}'`
  echo $(( stage * DEPLOY_PART_PERCENTAGE / stages_count ))
  echo "$status"
  exit
fi

$my_dir/_set-juju-creds.sh &>/dev/null

if ! juju status &>/dev/null ; then
  echo "-1"
  echo "Deployment is not started yet or has been destroyed."
  exit
fi

all_units=`juju status --format oneline | grep "workload:" | wc -l`
ready_units=`juju status --format line | grep "workload:active" | wc -l`
if (( all_units < 5 )) ; then
  echo "$DEPLOY_PART_PERCENTAGE"
  echo "Deploying is still in the process."
  exit
fi
if (( ready_units < all_units )) ; then
  echo $(( DEPLOY_PART_PERCENTAGE + ready_units * (100 - DEPLOY_PART_PERCENTAGE) / all_units ))
  echo "Deploying is still in the process."
  exit
fi

echo "100"

ip=`juju status --format line | awk '/ openstack-dashboard/{print $3}'`
echo "http://$ip/horizon"

ip=`juju status --format line | awk '/ contrail-controller/{print $3}'`
echo "http://$ip:8080/"

# not needed now
#ip=`juju status --format line | awk '/ contrail-controller/{print $3}'`
#echo "http://$ip:5000/"
