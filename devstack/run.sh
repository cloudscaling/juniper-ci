#!/bin/bash -e

localrc_file=$1
if [ -z "$localrc_file" ] ; then
  echo "ERROR: first argument is absent. It should be a name of localrc file for devstack"
  exit 1
fi

test_suite=$2
if [ -z "$test_suite" ] ; then
  echo "ERROR: second argument is absent. It should be a name of test_suite"
  exit 1
fi

concurrency=${3:-1}

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

rm -rf logs

trap catch_errors ERR;

function catch_errors() {
  local exit_code=$?
  echo "Errors!" $exit_code $@

  $my_dir/save-logs-from-devstack.sh
  $my_dir/cleanup-devstack-cloud.sh

  exit $exit_code
}

if [[ "$CLEAN_BEFORE" == 'true' || "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
  $my_dir/cleanup-devstack-cloud.sh
  if [[ "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
    exit
  fi
fi

$my_dir/create-instance-for-devstack-cloud.sh

$my_dir/install-devstack.sh $my_dir/$localrc_file
timeout -s 9 3h $my_dir/run-tempest-inside-devstack.sh $test_suite $concurrency

trap - ERR
$my_dir/save-logs-from-devstack.sh
$my_dir/cleanup-devstack-cloud.sh
