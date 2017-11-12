#!/bin/bash -x

# save contrail files
mkdir -p logs/contrail
pushd logs/contrail
for cnt in `sudo docker ps | grep contrail | grep -v pause | awk '{print $1}'` ; do
  cnt_name=`sudo docker inspect $cnt | grep '"Name"' | head -1 | cut -d '_' -f 2,3`
  echo "Collecting files from $cnt_name"
  mkdir -p "$cnt_name"
  sudo docker inspect $cnt > "$cnt_name/inspect.log"
  sudo docker cp $cnt:/var/log/contrail "$cnt_name/"
  sudo ls -l "$cnt_name/contrail/"
  sudo ls -l "$cnt_name/contrail/"*
  sudo mv "$cnt_name/contrail/"* "$cnt_name/"
  sudo rm -rf "$cnt_name/contrail"
  sudo docker cp $cnt:/etc/contrail "$cnt_name/"
  sudo mv "$cnt_name/contrail" "$cnt_name/etc"
done
popd

function save_introspect_info() {
  curl -s http://localhost:$2/Snh_SandeshUVECacheReq?x=NodeStatus | xmllint --format - | grep -P "state|<type|<status" > logs/contrail/$1-introspect.log
  echo '' >> logs/contrail/$1-introspect.log
  curl -s http://localhost:$2/Snh_SandeshUVECacheReq?x=NodeStatus | xmllint --format - >> logs/contrail/$1-introspect.log
}

save_introspect_info HttpPortConfigNodemgr 8100
save_introspect_info HttpPortControlNodemgr 8101
save_introspect_info HttpPortVRouterNodemgr 8102
save_introspect_info HttpPortDatabaseNodemgr 8103
save_introspect_info HttpPortAnalyticsNodemgr 8104
save_introspect_info HttpPortStorageStatsmgr 8105
save_introspect_info HttpPortIpmiStatsmgr 8106
save_introspect_info HttpPortInventorymgr 8107
save_introspect_info HttpPortKubeManager 8108
save_introspect_info HttpPortMesosManager 8109

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
save_introspect_info HttpPortDiscovery 5997
