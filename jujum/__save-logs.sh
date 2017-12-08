#!/bin/bash

rm -f logs.*
tar -cf logs.tar /var/log/juju 2>/dev/null
for ldir in '/etc/apache2' '/etc/apt' '/etc/neutron' '/etc/nova' '/etc/haproxy' '/var/log/upstart' '/var/log/neutron' '/var/log/nova' '/etc/keystone' '/var/log/keystone' ; do
  if [ -d "$ldir" ] ; then
    tar -rf logs.tar "$ldir" 2>/dev/null
  fi
done

ps ax -H &> ps.log
netstat -lpn &> netstat.log
free -h &> mem.log
tar -rf logs.tar ps.log netstat.log mem.log 2>/dev/null

gzip logs.tar
