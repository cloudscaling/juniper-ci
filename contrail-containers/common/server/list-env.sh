#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source "$my_dir/../../../common/virsh/functions"

echo "Virtual machines:"
virsh list --all

echo
echo "/proc/meminfo"
cat /proc/meminfo | grep -i HugePages
