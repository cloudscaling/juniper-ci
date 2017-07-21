#!/bin/bash

rm -f logs.*
tar -cf logs.tar /var/log/juju 2>/dev/null
for ldir in '/etc/apache2' '/etc/apt' '/etc/contrail' '/etc/contrailctl' '/etc/neutron' '/etc/nova' '/etc/haproxy' '/var/log/upstart' '/var/log/neutron' '/var/log/nova' '/var/log/contrail' '/etc/keystone' '/var/log/keystone' ; do
  if [ -d "$ldir" ] ; then
    tar -rf logs.tar "$ldir" 2>/dev/null
  fi
done

ps ax -H &> ps.log
netstat -lpn &> netstat.log
free -hw &> mem.log
tar -rf logs.tar ps.log netstat.log mem.log 2>/dev/null

if which contrail-status &>/dev/null ; then
  contrail-status &>contrail-status.log
  tar -rf logs.tar contrail-status.log 2>/dev/null
fi

if which vif &>/dev/null ; then
  vif --list &>vif.log
  tar -rf logs.tar vif.log 2>/dev/null
  ifconfig &>if.log
  tar -rf logs.tar if.log 2>/dev/null
fi

if which docker ; then
  if docker ps | grep -q contrail ; then
    DL='docker-logs'
    mkdir -p "$DL"
    for cnt in agent controller analytics analyticsdb ; do
      if docker ps | grep -qw "contrail-$cnt" ; then
        ldir="$DL/contrail-$cnt"
        mkdir -p "$ldir"
        if grep -q trusty /etc/lsb-release ; then
          docker logs "contrail-$cnt" &>"./$ldir/$cnt.log"
        else
          docker exec "contrail-$cnt" journalctl -u contrail-ansible.service --no-pager --since "2017-01-01" &>"./$ldir/$cnt.log"
        fi
        docker exec contrail-$cnt contrail-status &>"./$ldir/contrail-status.log"
        docker exec contrail-$cnt free -hw &>"./$ldir/mem.log"
        if [[ "$cnt" == "controller" ]] ; then
          docker exec contrail-controller rabbitmqctl cluster_status &>"./$ldir/rabbitmq-cluster-status.log"
        fi
        docker cp "contrail-$cnt:/var/log/contrail" "./$ldir"
        mv "$ldir/contrail" "$ldir/var-log-contrail"
        docker cp "contrail-$cnt:/etc/contrail" "./$ldir"
        mv "$ldir/contrail" "$ldir/etc-contrail"
        for srv in rabbitmq cassandra zookeeper ; do
          if docker cp "contrail-$cnt:/etc/$srv" "./$ldir" ; then
            mv "$ldir/$srv" "$ldir/etc-$srv"
          fi
          if docker cp "contrail-$cnt:/var/log/$srv" "./$ldir" ; then
            mv "$ldir/$srv" "$ldir/var-log-$srv"
          fi
        done

        tar -rf logs.tar "$ldir" 2>/dev/null
      fi
    done
  fi
fi

gzip logs.tar
