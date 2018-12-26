#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

existed_vms=`virsh -q list --all | awk '{print $2}' | sort`

echo "Virtual machines:"
for vm in $existed_vms ; do
    echo $vm
done

echo
echo "Virtual machines\' dumps:"
for vm in $existed_vms ; do
    echo "Name: $vm"
    echo "Dump:"
    vm_dump=`virsh dumpxml $vm`
    echo "$vm_dump"
    echo
done
