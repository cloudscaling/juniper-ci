#!/bin/bash -e

if [[ "$HOME" == "" ]] ; then
  echo "ERROR: HOME variable must be set"
  exit 1
fi
prefix=""
if [ "$(whoami)" == "root" ] ; then
  user="$1"
  if [[ "$user" == "" || ! $(grep "apavlofv" /etc/passwd) ]] ; then
    echo "ERROR: script must run under non-root user with sudo priveleges or first parameter must be a user name form the system."
    exit 2
  fi
  prefix="sudo"
fi

$prefix apt-get -qq update
$prefix DEBIAN_FRONTEND=noninteractive apt-get -fqy -o Dpkg::Options::="--force-confnew" upgrade
$prefix apt-get install -fy juju awscli mc joe git jq curl

cd "$HOME"
rm -rf juniper-ci
git clone https://github.com/cloudscaling/juniper-ci.git

if [ "$(whoami)" == "root" ] ; then
  chown -R $user "$HOME"
fi
