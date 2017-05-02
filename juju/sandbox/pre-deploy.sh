#!/bin/bash -e

sudo apt-get -qq update
sudo DEBIAN_FRONTEND=noninteractive apt-get -fqy -o Dpkg::Options::=\"--force-confnew\" upgrade
sudo apt-get install -fqy juju awscli mc joe


