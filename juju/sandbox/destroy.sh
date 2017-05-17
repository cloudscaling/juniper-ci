#!/bin/bash

if [[ "$HOME" == "" ]] ; then
  echo "ERROR: HOME variable must be set"
  exit 1
fi

addresses_store_file="$HOME/.addresses"

function release_addresses() {
  for address_line in `cat "$addresses_store_file"` ; do
    ip=`echo "$address_line" | cut -d , -f 1`
    ip_id=`echo "$address_line" | cut -d , -f 2`

    if assoc_id=`aws ec2 describe-addresses --public-ip $ip --query "Addresses[*].AssociationId" --output text` ; then
      aws ec2 disassociate-address --association-id $assoc_id
      sleep 2
    fi
    aws ec2 release-address --allocation-id $ip_id
  done
}


release_addresses

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

$my_dir/_set-juju-creds.sh

juju destroy-controller -y --destroy-all-models amazon

release_addresses
rm -f "$addresses_store_file"
