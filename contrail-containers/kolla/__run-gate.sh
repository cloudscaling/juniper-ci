#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source ./check-functions

# assume that this file is in home directory of ssh_user
mkdir -p $my_dir/logs

function save_logs() {
  cp -r /var/lib/docker/volumes/kolla_logs/_data $my_dir/logs/ || /bin/true
}

trap 'catch_errors $LINENO' ERR EXIT
function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  set +x
  free -h | tee $my_dir/logs/free.log
  df -h | tee $my_dir/logs/df.log
  ps ax -H > $my_dir/logs/ps_ax.log
  docker ps -a
  save_logs
  exit $exit_code
}

# tune some host settings
sysctl -w vm.max_map_count=1048575

if [[ "$REGISTRY_INSECURE" == '1' ]] ; then
  mkdir -p /etc/docker
  cat <<EOF > /etc/docker/daemon.json
{
    "insecure-registries": ["$CONTAINER_REGISTRY"]
}
EOF
fi

kolla_path=''
if [[ -x $(command -v apt-get 2>/dev/null) ]]; then
  HOST_OS='ubuntu'
  kolla_path='/usr/local/share'
  sed -i -e "s/{{if1}}/ens3/g" globals.yml
  sed -i -e "s/{{if2}}/ens4/g" globals.yml
elif [[ -x $(command -v yum 2>/dev/null) ]]; then
  HOST_OS='centos'
  kolla_path='/usr/share'
  sed -i -e "s/{{if1}}/eth0/g" globals.yml
  sed -i -e "s/{{if2}}/eth1/g" globals.yml
else
  echo "ERROR: Unable to find apt-get or yum"
  exit 1
fi
sed -i -e "s/{{base_distro}}/$HOST_OS/g" globals.yml
sed -i -e "s/{{openstack_version}}/$OPENSTACK_VERSION/g" globals.yml
sed -i -e "s/{{contrail_tag}}/$CONTRAIL_VERSION/g" globals.yml
sed -i -e "s/{{contrail_docker_registry}}/$CONTAINER_REGISTRY/g" globals.yml
sed -i -e "s/{{opencontrail_ssl}}/$SSL_ENABLE/g" globals.yml


echo 'opencontrail_vrouter_gateway: "192.168.131.1"' >> globals.yml

echo "INFO: Preparing instances"
if [ "x$HOST_OS" == "xubuntu" ]; then
  apt-get install -y --no-install-recommends python-pip
  pip install -U pip setuptools
  hash -r
  apt-get install -y python-dev libffi-dev gcc libssl-dev python-selinux
elif [ "x$HOST_OS" == "xcentos" ]; then
  # ip is located in /usr/sbin that is not in path...
  export PATH=${PATH}:/usr/sbin

  yum install -y python-pip
  pip install -U pip
  hash -r
  yum install -y python-devel libffi-devel gcc openssl-devel libselinux-python
fi
pip install -U "ansible<2.5.0"

# TODO: switch to openstack's repo when work is done
#pip install kolla-ansible
git clone https://github.com/cloudscaling/kolla-ansible
cd kolla-ansible
pip install -r requirements.txt
python setup.py install
cd ..

cp -r $kolla_path/kolla-ansible/etc_examples/kolla /etc/kolla/
cp $kolla_path/kolla-ansible/ansible/inventory/* .
cp globals.yml /etc/kolla

kolla-genpwd
kolla-ansible -i all-in-one bootstrap-servers
kolla-ansible pull -i all-in-one
docker images

mkdir -p /etc/kolla/config/nova
cat <<EOF > /etc/kolla/config/nova/nova-compute.conf
[libvirt]
virt_type = qemu
cpu_mode = none
EOF

kolla-ansible prechecks -i all-in-one

kolla-ansible deploy -i all-in-one
docker ps -a
kolla-ansible post-deploy

sleep 30
contrail-status

# test it
pip install python-openstackclient
source /etc/kolla/admin-openrc.sh
$kolla_path/kolla-ansible/init-runonce

ret=0
prepare_openstack && check_simple_instance || ret=1

trap - ERR EXIT
save_logs

exit $ret
