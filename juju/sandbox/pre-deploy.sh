#!/bin/bash -e

if [[ "$HOME" == "" ]] ; then
  echo "ERROR: HOME variable must be set"
  exit 1
fi
prefix=""
if [ "$(whoami)" == "root" ] ; then
  user="$1"
  if [[ "$user" == "" || ! $(grep "$user" /etc/passwd) ]] ; then
    echo "ERROR: script must run under non-root user with sudo priveleges or first parameter must be a user name form the system."
    exit 2
  fi
else
  prefix="sudo"
fi

export DEBIAN_FRONTEND=noninteractive
${prefix} apt-get -qq update
${prefix} apt-get -fy -o Dpkg::Options::="--force-confnew" upgrade
${prefix} apt-get install -fy juju awscli mc joe git jq curl virtualenv python gcc python-dev

mkdir -p "$HOME"
cd "$HOME"
rm -rf juniper-ci
git clone https://github.com/cloudscaling/juniper-ci.git

if [ "$(whoami)" == "root" ] ; then
  chown -R $user "$HOME"
fi
