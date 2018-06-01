#!/bin/bash

CNT_NAME_PATTERN=${CNT_NAME_PATTERN:-'2,3'}

SSL_ENABLE=${SSL_ENABLE:-'false'}
SERVER_CERTFILE=${SERVER_CERTFILE:-'/etc/contrail/ssl/certs/server.pem'}
SERVER_KEYFILE=${SERVER_KEYFILE:-'/etc/contrail/ssl/private/server-privkey.pem'}

proto='http'
if [[ "${SSL_ENABLE,,}" == 'true' ]] ; then
  proto='https'
  ssl_opts="-k --key ${SERVER_KEYFILE} --cert ${SERVER_CERTFILE}"
fi

# save contrail files
mkdir -p logs
sudo chown -R $USER logs

if [ -d /etc/contrail ]; then
  mkdir -p logs/etc
  cp -R /etc/contrail logs/etc/
  chown -R $USER logs/etc
fi

mkdir -p logs/contrail
pushd logs/contrail
for cnt in `sudo docker ps | grep contrail | grep -v pause | awk '{print $1}'` ; do
  cnt_name=`sudo docker inspect $cnt | python -c "import json, sys; data=json.load(sys.stdin); print data[0]['Name']" | cut -d '_' -f $CNT_NAME_PATTERN | sed "s|/||g"`
  echo "Collecting files from $cnt_name"
  mkdir -p "$cnt_name"
  sudo docker cp $cnt:/var/log/contrail $cnt_name/
  sudo chown -R $USER $cnt_name
  mv $cnt_name/contrail/* $cnt_name/
  rm -rf $cnt_name/contrail
  sudo docker cp $cnt:/etc/contrail $cnt_name/
  sudo chown -R $USER $cnt_name
  mv $cnt_name/contrail $cnt_name/etc
done
for cnt in `sudo docker ps -a | grep contrail | grep -v pause | awk '{print $1}'` ; do
  cnt_name=`sudo docker inspect $cnt | python -c "import json, sys; data=json.load(sys.stdin); print data[0]['Name']" | cut -d '_' -f $CNT_NAME_PATTERN | sed "s|/||g"`
  mkdir -p "$cnt_name"
  sudo docker inspect $cnt > $cnt_name/inspect.log
  sudo docker logs $cnt &> $cnt_name/docker.log
done
popd

sudo /usr/bin/contrail-status |& tee logs/contrail/contrail-status.log

function save_introspect_info() {
  echo "INFO: saving introspect output for $1"
  timeout -s 9 30 curl $ssl_opts -s ${proto}://localhost:$2/Snh_SandeshUVECacheReq?x=NodeStatus | xmllint --format - | grep -P "state|<type|<status" > logs/contrail/$1-introspect.log
  echo '' >> logs/contrail/$1-introspect.log
  timeout -s 9 30 curl $ssl_opts -s ${proto}://localhost:$2/Snh_SandeshUVECacheReq?x=NodeStatus | xmllint --format - >> logs/contrail/$1-introspect.log
}

save_introspect_info HttpPortConfigNodemgr 8100
save_introspect_info HttpPortControlNodemgr 8101
save_introspect_info HttpPortVRouterNodemgr 8102
save_introspect_info HttpPortDatabaseNodemgr 8103
save_introspect_info HttpPortAnalyticsNodemgr 8104
save_introspect_info HttpPortKubeManager 8108
#save_introspect_info HttpPortMesosManager 8109

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
