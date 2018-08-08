#!/bin/bash -ex

yum install -y iptables
iptables -S FORWARD | awk '/icmp/{print "iptables -D ",$2,$3,$4,$5,$6,$7,$8}' | bash
