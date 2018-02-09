#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

# ip is located in /usr/sbin that is not in path...
export PATH=${PATH}:/usr/sbin

echo "INFO: Run setup-for-build  $(date)"

cd contrail-container-builder/containers

# there are 30 images (all images without base images)
# TODO: make check not so strong, add check for version/distro/openstack-version
if [ -d $HOME/containers-cache ] && (( $(ls -l $HOME/containers-cache | grep 'contrail-' | wc -l) >= 24 )) ; then
  echo "INFO: using cached containers... $(date)"
  ./validate-docker.sh
  ./install-registry.sh

  default_interface=`ip route show | grep "default via" | awk '{print $5}'`
  default_ip=`ip address show dev $default_interface | head -3 | tail -1 | tr "/" " " | awk '{print $2}'`

  for ff in `ls $HOME/containers-cache` ; do
    gunzip -c $HOME/containers-cache/$ff | sudo docker load
    id=`sudo docker images | awk '/<none>/{print $3}'`
    name=`echo $ff | sed "s/-$CONTRAIL_VERSION.*//"`
    tag=`echo $ff | sed "s/$name-//" | sed 's/.tgz//'`
    sudo docker tag $id "$default_ip:5000/$name:$tag"
    sudo docker push "$default_ip:5000/$name:$tag"
  done
else
  ./setup-for-build.sh
  echo "INFO: Run build  $(date)"
  sudo -E ./build.sh || /bin/true
fi

sudo docker images | grep "$CONTRAIL_VERSION"

echo "INFO: Build finished  $(date)"
