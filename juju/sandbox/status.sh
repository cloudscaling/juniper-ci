#!/bin/bash -e

DEPLOY_PART_PERCENTAGE=24

if [[ "$HOME" == "" ]] ; then
  echo "ERROR: HOME variable must be set"
  exit 1
fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

# output stage:
# -5 = juju deployment failed
# -4 = invalid deployment state
# -2 = juju reset in progress
# -1 = there is no juju deployment
# 0-99 = juju deployment is in progress
# 100 = juju deployment finished

# input stage:
# -2 = juju reset in progress
# 0-99 = juju deployment is in progress
# 100 = juju deployment finished
# input stages_count = 0 for negative stages

# reads and updates global variables
function read_status_file() {
  stage=`cat $HOME/deploy_status.$1 | sed -n -e '1{p;q}'`
  stages_count=`cat $HOME/deploy_status.$1 | sed -n -e '2{p;q}'`
  status=`cat $HOME/deploy_status.$1 | sed -n -e '3{p;q}'`
}

pid=''
for ff in `ls $HOME/deploy_status.*` ; do
  cpid=`echo $ff | cut -d '.' -f 2`
  if kill -0 $cpid &>/dev/null ; then
    if [ -n "$pid" ] ; then
      echo "-4"
      echo "Multiple processes are found. Can't calculate state. Please delete this SandBox."
      exit
    fi
    pid="$cpid"
  else
    read_status_file "$cpid"
    if [[ "$stage" == -2 ]] ; then
      # it means that destroy.sh script was failed/killed in the middle. deployment can be invalid.
      echo "-4"
      echo "Destroy was unsuccessful in the middle. Deployment is in invalid state. Please delete this SandBox."
    else
      # it means that deploy.sh script was failed/killed in the middle. deployment can be invalid.
      echo "-5"
      echo "Deploy was unsuccessful in the middle. Deployment is in invalid state. Please redeploy (reset/deploy) or delete this SandBox."
    fi
  fi
done

if [ -n "$pid" ] ; then
  read_status_file "$pid"
  if [[ "$stages_count" == '0' ]] ; then
    echo $stage
    echo "$status"
  else
    echo $(( stage * DEPLOY_PART_PERCENTAGE / stages_count ))
    echo "$status"
  fi
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
