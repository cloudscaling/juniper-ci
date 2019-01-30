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
chown -R $USER logs

if [ -d /etc/contrail ]; then
  mkdir -p logs/etc_contrail
  cp -R /etc/contrail logs/etc_contrail/
  chown -R $USER logs/etc_contrail
fi
if [ -d /etc/cni ]; then
  mkdir -p logs/etc_cni
  cp -R /etc/cni logs/etc_cni/
  chown -R $USER logs/etc_cni
fi
if [ -d /etc/kolla ]; then
  mkdir -p logs/kolla_etc
  cp -R /etc/kolla logs/kolla_etc/
  chown -R $USER logs/kolla_etc
fi

ls -l /var/lib/docker/volumes/
kl_path='/var/lib/docker/volumes/kolla_logs/_data'
if [ -d $kl_path ]; then
  mkdir -p logs/kolla_logs
  for ii in `ls $kl_path/`; do
    cp -R "$kl_path/$ii" logs/kolla_logs/
  done
  chown -R $USER logs/kolla_logs
  chmod -R a+rw logs/kolla_logs
fi

cl_path='/var/log/contrail'
if [ -d $cl_path ]; then
  mkdir -p logs/contrail_logs
  for ii in `ls $cl_path/`; do
    cp -R "$cl_path/$ii" logs/contrail_logs/
  done
  chown -R $USER logs/contrail_logs
  chmod -R a+rw logs/contrail_logs
fi

if [[ -x $(command -v kubectl 2>/dev/null) ]] ; then
  export PATH=${PATH}:/usr/sbin
  mkdir -p logs/kube-info
  kubectl get nodes -o wide > logs/kube-info/nodes 2>&1
  kubectl get pods -o wide --all-namespaces=true > logs/kube-info/pods 2>&1
  kubectl get all -o wide --all-namespaces=true > logs/kube-info/apps 2>&1
fi
for i in ~/my-contrail.yaml ~/test_app.yaml ; do
  if [ -f $i ] ; then
    cp $i logs/
  fi
done

mkdir -p logs/contrail
pushd logs/contrail
for cnt in `docker ps | grep contrail | grep -v pause | awk '{print $1}'` ; do
  cnt_name=`docker inspect $cnt | python -c "import json, sys; data=json.load(sys.stdin); print data[0]['Name']" | cut -d '_' -f $CNT_NAME_PATTERN | sed "s|/||g"`
  echo "Collecting files from $cnt_name"
  mkdir -p "$cnt_name"
  docker cp $cnt:/etc/contrail $cnt_name/
  chown -R $USER $cnt_name
  mv $cnt_name/contrail $cnt_name/etc
done
for cnt in `docker ps -a | grep contrail | grep -v pause | awk '{print $1}'` ; do
  cnt_name=`docker inspect $cnt | python -c "import json, sys; data=json.load(sys.stdin); print data[0]['Name']" | cut -d '_' -f $CNT_NAME_PATTERN | sed "s|/||g"`
  mkdir -p "$cnt_name-$cnt"
  docker inspect $cnt > $cnt_name-$cnt/inspect.log
  docker logs $cnt &> $cnt_name-$cnt/docker.log
done
popd

/usr/bin/contrail-status |& tee logs/contrail/contrail-status.log
url=$(hostname -f)
function save_introspect_info() {
  if ! lsof -i ":$2" &>/dev/null ; then
    return
  fi
  echo "INFO: saving introspect output for $1"
  timeout -s 9 30 curl $ssl_opts -s ${proto}://${url}:$2/Snh_SandeshUVECacheReq?x=NodeStatus | xmllint --format - | grep -P "state|<type|<status" > logs/contrail/$1-introspect.log
  echo '' >> logs/contrail/$1-introspect.log
  timeout -s 9 30 curl $ssl_opts -s ${proto}://${url}:$2/Snh_SandeshUVECacheReq?x=NodeStatus | xmllint --format - >> logs/contrail/$1-introspect.log
}

save_introspect_info HttpPortConfigNodemgr 8100
save_introspect_info HttpPortControlNodemgr 8101
save_introspect_info HttpPortVRouterNodemgr 8102
save_introspect_info HttpPortDatabaseNodemgr 8103
save_introspect_info HttpPortAnalyticsNodemgr 8104
save_introspect_info HttpPortKubeManager 8108
#save_introspect_info HttpPortMesosManager 8109
save_introspect_info HttpPortConfigDatabaseNodemgr 8112
save_introspect_info HttpPortAnalyticsAlarmNodemgr 8113
save_introspect_info HttpPortAnalyticsSNMPNodemgr 8114
save_introspect_info HttpPortDeviceManagerNodemgr 8115

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
