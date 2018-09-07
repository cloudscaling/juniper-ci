#!/bin/bash

sudo apt-get install -fy libxml2-utils &>/dev/null

proto='http'
if [[ "${USE_SSL_CONTRAIL,,}" == 'true' ]] ; then
  proto='https'
  ssl_opts='--key /etc/contrail/ssl/server-privkey.pem --cert /etc/contrail/ssl/server.pem --cacert /etc/contrail/ssl/ca-cert.pem'
fi

rm -f logs.*
tar -cf logs.tar /var/log/juju 2>/dev/null
for ldir in "$HOME/logs" '/etc/apache2' '/etc/apt' '/etc/contrail' '/etc/contrailctl' '/etc/neutron' '/etc/nova' '/etc/haproxy' '/var/log/upstart' '/var/log/neutron' '/var/log/nova' '/var/log/contrail' '/etc/keystone' '/var/log/keystone' ; do
  if [ -d "$ldir" ] ; then
    tar -rf logs.tar "$ldir" 2>/dev/null
  fi
done

ps ax -H &> ps.log
netstat -lpn &> netstat.log
free -h &> mem.log
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
  ip route &>route.log
  tar -rf logs.tar route.log 2>/dev/null
fi

DL='docker-logs'
mkdir -p "$DL"
pushd "$DL"
for cnt in `sudo docker ps -a | grep contrail | grep -v pause | awk '{print $1}'` ; do
  cnt_name=`sudo docker inspect $cnt | python -c "import json, sys; data=json.load(sys.stdin); print data[0]['Name']" | sed "s|/||g"`

  echo "Collecting files from $cnt_name"
  mkdir -p "$cnt_name"
  sudo docker cp $cnt:/etc/contrail $cnt_name/
  sudo chown -R $USER $cnt_name
  mv $cnt_name/contrail $cnt_name/etc

  sudo docker inspect $cnt > $cnt_name/inspect.log
  sudo docker logs $cnt &> $cnt_name/docker.log
done
popd
tar -rf logs.tar $DL 2>/dev/null

host_ip=`hostname -i`
function save_introspect_info() {
  if ! lsof -i ":$2" &>/dev/null ; then
    return
  fi
  echo "INFO: saving introspect output for $1"
  timeout -s 9 30 curl $ssl_opts -s ${proto}://$host_ip:$2/Snh_SandeshUVECacheReq?x=NodeStatus | xmllint --format - | grep -P "state|<type|<status" > $1-introspect.log
  echo '' >> $1-introspect.log
  timeout -s 9 30 curl $ssl_opts -s ${proto}://$host_ip:$2/Snh_SandeshUVECacheReq?x=NodeStatus | xmllint --format - >> $1-introspect.log
  tar -rf logs.tar $1-introspect.log 2>/dev/null
}

save_introspect_info HttpPortConfigNodemgr 8100
save_introspect_info HttpPortControlNodemgr 8101
save_introspect_info HttpPortVRouterNodemgr 8102
save_introspect_info HttpPortDatabaseNodemgr 8103
save_introspect_info HttpPortAnalyticsNodemgr 8104
save_introspect_info HttpPortKubeManager 8108

save_introspect_info HttpPortControl 8083
save_introspect_info HttpPortApiServer 8084
save_introspect_info HttpPortAgent 8085
save_introspect_info HttpPortSchemaTransformer 8087
save_introspect_info HttpPortSvcMonitor 8088
save_introspect_info HttpPortDeviceManager 8096
save_introspect_info HttpPortCollector 8089
save_introspect_info HttpPortOpserver 8090
save_introspect_info HttpPortQueryEngine 8091
save_introspect_info HttpPortDns 8092
save_introspect_info HttpPortAlarmGenerator 5995
save_introspect_info HttpPortSnmpCollector 5920
save_introspect_info HttpPortTopology 5921

gzip logs.tar
