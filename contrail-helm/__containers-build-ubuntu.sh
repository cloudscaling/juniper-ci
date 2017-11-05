#!/bin/bash -ex

sudo apt-get install -y mini-httpd rpm2cpio
sudo sed -i "s/^host=.*$/host=0.0.0.0/g" /etc/mini-httpd.conf
sudo sed -i "s/^port=.*$/port=81/g" /etc/mini-httpd.conf
sudo sed -i "s/^START=.*$/START=1/g" /etc/default/mini-httpd
sudo killall mini_httpd || /bin/true
sudo service mini-httpd restart
wget -nv https://s3-us-west-2.amazonaws.com/contrailrhel7/contrail-install-packages-4.0.2.0-35~ocata.el7.noarch.rpm
rpm2cpio contrail-install-packages-4.0.2.0-35~ocata.el7.noarch.rpm | cpio -i --make-directories
sudo mkdir -p /var/www/html/contrail
sudo tar -xvf opt/contrail/contrail_packages/contrail_rpms.tgz -C /var/www/html/contrail/

git clone ${DOCKER_CONTRAIL_URL:-https://github.com/cloudscaling/docker-contrail-4}
sudo docker run -d -p 5000:5000 --restart=always --name registry registry:2
pushd docker-contrail-4
./change_contrail_version.sh 4.0.1.0-32 4.0.2.0-35
popd

cd docker-contrail-4
local_ip=`hostname -i`
for fn in `grep -r -l 10.0.2.15/contrail *`; do sed "s/10.0.2.15/$local_ip:81/g" < "$fn" > result; rm "$fn"; mv result "$fn"; done
for fn in `grep -r -l 10.0.2.15 *`; do sed "s/10.0.2.15/$local_ip/g" < "$fn" > result; rm "$fn"; mv result "$fn"; done
cd containers
sudo ./build.sh || /bin/true
sudo docker images | grep "0-35"
sudo ./build.sh || /bin/true
sudo docker images | grep "0-35"
