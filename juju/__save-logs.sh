#!/bin/bash

rm -f logs.*
tar -cf logs.tar /var/log/juju
for ldir in '/etc/apache2' '/etc/apt' '/etc/contrail' '/etc/contrailctl' '/etc/neutron' '/etc/nova' '/var/log/upstart' '/var/log/neutron' '/var/log/nova' '/var/log/contrail' ; do
  if [ -d "$ldir" ] ; then
    tar -rf logs.tar "$ldir"
  fi
done

if which contrail-status ; then
  contrail-status &>contrail-status.log
  tar -rf logs.tar contrail-status.log
fi

if which vif ; then
  vif --list &>vif.log
  tar -rf logs.tar vif.log
fi

if docker ps | grep -q contrail ; then
  DL='docker-logs'
  mkdir -p "$DL"
  for cnt in agent controller analytics analyticsdb ; do
    if docker ps | grep -qw "contrail-$cnt" ; then
      ldir="$DL/contrail-$cnt"
      mkdir -p "$ldir"
      docker logs "contrail-$cnt" &>"./$ldir/$cnt.log"
      docker exec contrail-$cnt contrail-status &>"./$ldir/contrail-status.log"
      docker cp "contrail-$cnt:/var/log/contrail" "./$ldir"
      mv "$ldir/contrail" "$ldir/contrail-logs"
      docker cp "contrail-$cnt:/etc/contrail" "./$ldir"
      mv "$ldir/contrail" "$ldir/contrail-etc"

      tar -rf logs.tar "$ldir"
    fi
  done
fi

gzip logs.tar