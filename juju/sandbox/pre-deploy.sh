#!/bin/bash -e

export VERSION=${VERSION:-'3062'}
export OPENSTACK_VERSION=${OPENSTACK_VERSION:-'mitaka'}
export CHARMS_VERSION=${CHARMS_VERSION:-'98b03eec82958b77777c0b53e6292a065ef57bf9'}

sudo apt-get -qq update
sudo DEBIAN_FRONTEND=noninteractive apt-get -fqy -o Dpkg::Options::="--force-confnew" upgrade
sudo apt-get install -fy juju awscli mc joe git jq curl

git clone https://github.com/cloudscaling/juniper-ci.git

./juniper-ci/juju/sandbox/deploy.sh
