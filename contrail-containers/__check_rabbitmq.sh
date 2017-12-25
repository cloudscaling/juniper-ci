#!/bin/bash

docker_id=$(docker ps | awk '/rabbitmq/{print($1)}' | head -n 1)
if [[ -z "$docker_id" ]] ; then
    echo "ERROR: failed to find rabbitmq container"
    exit -1
fi

res=0
rb_node="contrail@$(hostname)"
result=$(docker exec $docker_id rabbitmqctl -n $rb_node cluster_status 2>&1)
nodes=$(echo "$result" | grep -A 2 '{nodes,' | grep -c 'contrail@node')
running_nodes=$(echo "$result" | grep -A 2 '{running_nodes,' | grep -c 'contrail@node')
if (( nodes != 3 || running_nodes != nodes )) ; then
    echo "ERROR: rabbitmq cluster_state is wrong"
    res=-1
else
    echo "INFO: rabbitmq cluster_state"
fi
echo "$result"
exit $res
