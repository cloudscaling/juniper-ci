#!/bin/bash

if [[ "$HOME" == "" ]] ; then
  echo "ERROR: HOME variable must be set"
  exit 1
fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

$my_dir/_set-juju-creds.sh

juju destroy-controller -y --destroy-all-models amazon
