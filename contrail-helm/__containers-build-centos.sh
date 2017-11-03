#!/bin/bash -ex

sudo yum install -y httpd; sudo chkconfig httpd on; sudo service httpd start
sudo sed -i "s/^Listen .*$/Listen 81/g" /etc/httpd/conf/httpd.conf
sudo service httpd restart
wget -nv https://s3-us-west-2.amazonaws.com/contrailrhel7/contrail-install-packages-4.0.2.0-35~ocata.el7.noarch.rpm
sudo rpm -ivh contrail-install-packages-4.0.2.0-35~ocata.el7.noarch.rpm
sudo mkdir -p /var/www/html/contrail
sudo tar -xvf /opt/contrail/contrail_packages/contrail_rpms.tgz -C /var/www/html/contrail/

git clone https://github.com/cloudscaling/docker-contrail-4
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
