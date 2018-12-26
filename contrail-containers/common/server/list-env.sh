#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/../../../common/virsh/functions"

existed_vms=`virsh -q list --all | awk '{print $2}' | sort`

echo "Virtual machines:"
for vm in $existed_vms ; do
    echo $vm
done

echo
echo "/proc/meminfo"
cat /proc/meminfo
