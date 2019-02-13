#!/bin/bash -eE

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

# ip is located in /usr/sbin that is not in path...
export PATH=${PATH}:/usr/sbin

echo "INFO: Run setup-for-build  $(date)"

git config --global user.email john@google.com
ccb_dir=$HOME/contrail-container-builder
[ -d ${ccb_dir} ] || git clone https://github.com/Juniper/contrail-container-builder ${ccb_dir}
if patchlist=`grep "/contrail-container-builder " $HOME/patches` ; then
  pushd $ccb_dir >/dev/nul
  eval "$patchlist"
  popd >/dev/nul
fi

cd $HOME/contrail-container-builder/containers

./setup-for-build.sh

#baseurl = http://contrail-tpc.s3-website-us-west-2.amazonaws.com
cat <<EOF >../tpc.repo.template
[tpc]
name = Contrail repo
baseurl = http://148.251.5.90/tpc
enabled = 1
gpgcheck = 0
EOF

echo "INFO: Run build  $(date)"
sudo -E ./build.sh || /bin/true

sudo docker images | grep "$CONTRAIL_VERSION"

# cause we use this machine for cloud after build process then we need to free port 80
sudo systemctl stop lighttpd.service
sudo systemctl disable lighttpd.service

echo "INFO: Build finished  $(date)"
