apt install -y docker.io

port=$1
registry_name="registry_${port}"
if ! sudo docker ps --all | grep -q "${registry_name}" ; then
  echo "Start new Docker Registry on port $port"
  sudo docker run -d --restart=always --name $registry_name\
    -v /opt:/var/lib/registry:Z \
    -e REGISTRY_HTTP_ADDR=0.0.0.0:$port -p $port:$port \
    registry:2
else
  if ! sudo docker ps | grep -q "${registry_name}" ; then
    id=`sudo docker ps --all | grep "${registry_name}" | awk '{print($1)}'`
    echo "Docker Registry on port $port is already created but stopped, start it"
    sudo docker start $id
  else
    echo "Docker Registry is already started with port $port"
  fi
fi

for ff in `ls ./docker_images/*` ; do
  echo "Loading $ff"
  docker load -i $ff
done

for ii in "contrail-controller" "contrail-analytics" "contrail-analyticsdb" ; do
  image_id=`docker images | grep $ii- | awk '{print $3}'`
  docker tag $image_id localhost:$port/$ii:latest
  echo "INFO: Pushing $ii to local registry"
  docker push localhost:$port/$ii:latest
done
