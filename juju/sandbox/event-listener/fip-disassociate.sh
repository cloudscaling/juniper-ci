#!/bin/bash -eux

my_file="$(readlink -e "$0")"
my_dir="$(dirname ${my_file})"

fip=$1

#TODO: rework functions.sh - use parameters instead io global vars
# expects:
#   vm_uuid
#   fip
# adds variables:
#       ssh_cmd
#       primary_private_ip
#       secondary_private_ips
source ${my_dir}/functions.sh

remove_fip_vgw_subnets ${fip}

