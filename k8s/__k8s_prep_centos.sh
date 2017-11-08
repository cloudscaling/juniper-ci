#!/bin/bash -ex

#TODO: it is just as readme

pushd docker-contrail-4

kubernetes/setup-k8s.sh

docker pull docker.io/opencontrail/contrail-kubernetes-agent-ubuntu16.04:4.0.1.0
docker tag docker.io/opencontrail/contrail-kubernetes-agent-ubuntu16.04:4.0.1.0 192.168.222.197:5000/contrail-kubernetes-agent-ubuntu16.04:4.0.2.0-35
docker tag docker.io/opencontrail/contrail-kubernetes-agent-ubuntu16.04:4.0.1.0 192.168.222.197:5000/contrail-kubernetes-agent-ubuntu16.04:4.0.1.0

cp common.env.sample > common.env
# edit common.env


pushd kubernetes/manifests/
./resolve-manifest.sh <contrail-micro.yaml >my-contrail-micro.yaml
popd

popd

kubectl create -f docker-contrail-4/kubernetes/manifests/my-contrail-micro.yaml


# for applicaitons:
      # tolerations:
      # - operator: "Exists"
      #   effect: "NoSchedule" 