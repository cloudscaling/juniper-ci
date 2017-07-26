#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

test_suite=$1
concurrency=${2:-1}

ENV_FILE="cloudrc"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30"

source $ENV_FILE
SSH_DEST="ubuntu@$public_ip"
SSH="ssh -i kp $SSH_OPTS $SSH_DEST"
SCP="scp -i kp $SSH_OPTS"

rm -f *.xml
echo "running tests"
echo -------------------------------------------------------------------------- $(date)
$SSH "cd /opt/stack/tempest; tox -eall-plugin -- $test_suite --concurrency=$concurrency"
exit_code=$?
echo -------------------------------------------------------------------------- $(date)

suite=`basename "$(readlink -f .)"`
# to run next python module library 'extras' must be installed:
# sudo pip install extras
$SSH "cd /opt/stack/tempest ; testr last --subunit | subunit-1to2" | python "$my_dir/../tempest/subunit2jenkins.py" -o test_result.xml -s $suite
