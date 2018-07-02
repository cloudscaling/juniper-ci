#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source ~/stackrc

count=0
while openstack stack list | grep -q overcloud ; do
  if ! openstack stack list | grep overcloud | grep -qi 'delete' ; then
    openstack stack delete --yes overcloud || true
  fi
  if (( count > 300 )) ; then
    echo "WARNING: failed to wait while stack is deleted"
    break
  fi
  sleep 5
  ((count+=1))
done
