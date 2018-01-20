#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source $my_dir/functions

prepare_build_machine
# ip is located in /usr/sbin that is not in path...
export PATH=${PATH}:/usr/sbin

echo "INFO: Run setup-for-build  $(date)"

cd contrail-container-builder/containers

# there are 30 images (all images without base images)
if [ -d $HOME/containers-cache ] && [[ $(ls -l $HOME/containers-cache | grep 'contrail-' | wc -l) == '30' ]] ; then
  echo "INFO: using cached containers... $(date)"
  ./validate-docker.sh
  ./install-registry.sh

  for ff in `ls $HOME/containers-cache` ; do
    gunzip -c $HOME/containers-cache/$ff | sudo docker load
  done
else
  ./setup-for-build.sh
  echo "INFO: Run build  $(date)"
  sudo -E ./build.sh || /bin/true
fi

sudo docker images | grep "$CONTRAIL_VERSION"

echo "INFO: Build finished  $(date)"
