#!/bin/bash -e

VERSION='3062'
OPENSTACK_VERSION='mitaka'
CHARMS_VERSION='98b03eec82958b77777c0b53e6292a065ef57bf9'
ACCESS_KEY=''
SECRET_KEY=''

sudo apt-get -qq update
sudo DEBIAN_FRONTEND=noninteractive apt-get -fqy -o Dpkg::Options::="--force-confnew" upgrade
sudo apt-get install -fy juju awscli mc joe git jq curl

cat >creds.yaml <<EOF
credentials:
  aws:
    aws:
      auth-type: access-key
      access-key: $ACCESS_KEY
      secret-key: $SECRET_KEY
EOF
juju add-credential aws -f ~/creds.yaml
region=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r ".region"`
juju set-default-region aws $region

git clone https://github.com/cloudscaling/juniper-ci.git

export $VERSION
export $OPENSTACK_VERSION
export $CHARMS_VERSION

./juniper-ci/juju/sandbox/deploy.sh
