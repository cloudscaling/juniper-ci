#!/bin/bash

# Get charms sources

cd ~
cp ~/contrail-charms/examples/nested-mode-test.yaml ~/nested-mode-test.yaml
rm -rf ~/contrail-charms
git clone https://github.com/coderoot/contrail-charms
cd ~/contrail-charms
git checkout R5-k8s-nested-mode

cp ~/nested-mode-test.yaml ~/contrail-charms/examples/nested-mode-test.yaml

# Install juju and add machines

sudo snap install juju --classic

juju bootstrap manual/ubuntu@192.168.1.4 cont
juju add-machine ssh:ubuntu@$192.168.1.5
juju add-machine ssh:ubuntu@$192.168.1.6

cd ~/contrail-charms
juju deploy ./examples/nested-mode-test.yaml --map-machines=existing
