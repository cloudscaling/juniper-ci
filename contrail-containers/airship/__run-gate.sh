#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

mkdir -p $my_dir/logs
source "$my_dir/cloudrc"

git clone https://github.com/openstack/airship-in-a-bottle
git clone https://git.openstack.org/openstack/airship-pegleg.git
git clone https://git.openstack.org/openstack/airship-shipyard.git

sed -i 's/-it/-i/g' airship-pegleg/tools/pegleg.sh

cd ./airship-in-a-bottle/manifests/dev_single_node
./airship-in-a-bottle.sh -y
