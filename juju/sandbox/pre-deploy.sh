#!/bin/bash -e

sudo apt-get -qq update
sudo DEBIAN_FRONTEND=noninteractive apt-get -fqy -o Dpkg::Options::="--force-confnew" upgrade
sudo apt-get install -fy juju awscli mc joe git jq curl

mkdir -p /opt
rm -rf juniper-ci
git clone https://github.com/cloudscaling/juniper-ci.git
./juniper-ci/juju/sandbox/deploy.sh
