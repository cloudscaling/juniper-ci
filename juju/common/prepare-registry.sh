#!/bin/bash -e

sudo apt-get update
sudo apt-get install \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"
sudo apt-get update
sudo apt-get install -y docker-ce

echo "Start new Docker Registry"
sudo docker run -d --restart=always --name registry_5000\
  -v /opt:/var/lib/registry:Z \
  -e REGISTRY_HTTP_ADDR=0.0.0.0:5000 -p 5000:5000 \
  registry:2

for ff in `ls ./docker_images/*` ; do
  echo "Loading $ff"
  docker load -i $ff
done

for ii in "contrail-controller" "contrail-analytics" "contrail-analyticsdb" ; do
  image_id=`docker images | grep ${ii}- | awk '{print $3}'`
  image_name=`docker images | grep ${ii}- | awk '{print $1}'`
  image_tag=`docker images | grep ${ii}- | awk '{print $2}'`
  docker tag $image_id localhost:5000/$image_name:$image_tag
  echo "INFO: Pushing $image_name:$image_tag to local registry"
  docker push localhost:5000/$image_name:$image_tag
done
