#!/bin/bash

declare -A port_map
port_map['agent-vrouter']=8085
port_map['analytics-topology']=5921
port_map['config-nodemgr']=8100
port_map['control-nodemgr']=8101
port_map['vrouter-nodemgr']=8102
port_map['analytics-nodemgr']=8104
port_map['analytics-alarm-gen']=5995
#port_map['analytics-api']=
port_map['analytics-snmp-collector']=5920
port_map['analytics-collector']=8089
port_map['analytics-query-engine']=8091
port_map['controller-control-dns']=8092
port_map['controller-control-control']=8083
port_map['controller-config-api']=8084
port_map['controller-config-svcmonitor']=8088
port_map['controller-config-devicemgr']=8096
port_map['controller-config-schema']=8087
port_map['kube-manager']=8108
port_map['opserver']=8090

function get_introspect_state() {
  local app=$1
  local port=${port_map[${app}]}

  if ! lsof -i ":${port}" > /dev/null 2>&1; then
    echo 'skip'
    return
  fi

  local raw_res=$(timeout -s 9 30 curl -s http://localhost:${port}/Snh_SandeshUVECacheReq?x=NodeStatus 2>&1)
  if [[ ! $? -eq 0 ]] ; then
    echo "ERROR: failed to request  state"
    echo "$raw_res"
    return -1
  fi

  local res=$(echo "$raw_res" | xmllint --format - 2>&1)
  if [[ ! $? -eq 0 ]] ; then
    echo "ERROR: failed to parse xml-doc of introspection state"
    echo "ERROR: input xml-doc"
    echo "$raw_res"
    echo "ERROR: xmllint output"
    echo "$res"
    return -1
  fi

  echo "$res" | grep "<state" | grep -o '>.*<' | sed 's/[<>]//g'
}

count=0
err=0
skip=0
node=$(hostname)
for s in ${!port_map[@]} ; do
  state=$(get_introspect_state $s)
  case $state in
    skip)
      echo "INFO: $node: $s $state"
      (( skip+=1 ))
      ;;
    Functional)
      echo "INFO: $node: $s $state"
      (( count+=1 ))
      ;;
    Non-Functional)
      echo "ERROR: $node: $s $state"
      (( err+=1 ))
      ;;
    *)
      echo "ERROR: $node: $s $state"
      (( err+=1 ))
      ;;
  esac
done

echo "TRACE: Functional=$count err=$err skip=$skip"
exit $err
