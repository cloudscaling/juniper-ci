#!/bin/bash -eux

my_file="$(readlink -e "$0")"
my_dir="$(dirname ${my_file})"

vm_uuid=$1
fip=${2:-''}

#TODO: nothing to do for now
# expects:
#   vm_uuid
#   fip
# adds variables:
#       ssh_cmd
#       primary_private_ip
#       secondary_private_ips
#source ${my_dir}/functions.sh


