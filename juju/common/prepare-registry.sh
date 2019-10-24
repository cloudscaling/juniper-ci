#!/bin/bash -eE

repo_ip=$1
docker_user=$2
docker_password=$3

sudo apt-get install apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo apt-get update
sudo apt-get install -y docker-ce

# Configuring Docker
cat << EOF >> /etc/docker/daemon.json
{
  "insecure-registries" : ["${repo_ip}:5000"]
}
EOF

systemctl daemon-reload
service docker restart

echo "Start new Docker Registry"
sudo docker pull registry:2 &>/dev/null
mkdir auth
sudo docker run --entrypoint htpasswd registry:2 -Bbn $docker_user $docker_password > auth/htpasswd
sudo docker run -d --restart=always --name registry_5000\
  -v /opt:/var/lib/registry:Z \
  -v `pwd`/auth:/auth \
  -e "REGISTRY_AUTH=htpasswd" \
  -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" \
  -e "REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd" \
  -e REGISTRY_HTTP_ADDR=0.0.0.0:5000 -p 5000:5000 \
  registry:2
docker login -u $docker_user -p $docker_password ${repo_ip}:5000

for ff in `ls -1 ./docker_images/* | grep $CONTRAIL_BUILD` ; do
  echo "Loading $ff"
  res=`docker load -q -i $ff`
  echo "$res"
  if echo "$res" | grep -o "sha256:.*" ; then
    image_id=`echo "$res" | grep -o "sha256:.*" | cut -d ':' -f "2"`
    docker images | grep ${image_id:0:12}
    image_name=`docker images | grep ${image_id:0:12} | awk '{print $1}'`
    image_tag=`docker images | grep ${image_id:0:12} | awk '{print $2}'`
  else
    # image file has properties inside. just grep them.
    image_id=`echo $res | awk '{print $3}'`
    image_name=`echo $image_id | cut -d ':' -f 1`
    image_tag=`echo $image_id | cut -d ':' -f 2`
  fi
  echo "INFO: Pushing $image_name:$image_tag (with id $image_id) to local registry"
  docker tag $image_id ${repo_ip}:5000/$image_name:$image_tag
  docker push ${repo_ip}:5000/$image_name:$image_tag &>/dev/null
done
