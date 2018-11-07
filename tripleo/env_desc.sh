#!/bin/sh

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

poolname="rdimages"

# define undercloud virtual machine's names
undercloud_prefix="undercloud"
undercloud_vmname="rd-undercloud-$NUM"
undercloud_cert_vmname="rd-undercloud-$NUM-cert-test"
undercloud_freeipa_vmname="rd-undercloud-$NUM-freeipa"

#define virtual machine's volumes

undercloud_vm_volume="$undercloud_prefix-$NUM.qcow2"
undercloud_cert_vm_volume="$undercloud_prefix-$NUM-cert-test.qcow2"
undercloud_freeipa_vm_volume="$undercloud_prefix-$NUM-freeipa.qcow2"

# network names and settings
BRIDGE_NAME_MGMT=${BRIDGE_NAME_MGMT:-"e${NUM}-mgmt"}
BRIDGE_NAME_PROV=${BRIDGE_NAME_PROV:-"e${NUM}-prov"}
NET_NAME_MGMT=${NET_NAME_MGMT:-${BRIDGE_NAME_MGMT}}
NET_NAME_PROV=${NET_NAME_PROV:-${BRIDGE_NAME_PROV}}


source "$my_dir/../common/virsh/functions"

# define MAC's
mgmt_subnet=$(get_network_ip "management")
mgmt_gateway="${mgmt_subnet}.1"
mgmt_ip="${mgmt_subnet}.2"

prov_subnet=$(get_network_ip "provisioning")
prov_gateway="${prov_subnet}.1"
prov_ip="${prov_subnet}.2"
