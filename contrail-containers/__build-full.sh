#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

# ip is located in /usr/sbin that is not in path...
export PATH=${PATH}:/usr/sbin

linux=$(awk -F"=" '/^ID=/{print $2}' /etc/os-release | tr -d '"')

case "${linux}" in
  "ubuntu" )
    apt-get install -y docker.io
    ;;
  "centos" | "rhel" )
    yum install -y docker
    ;;
esac

echo "INFO: Start build $(date)"

full_list=`printf "$PATCHSET_LIST\n${CCB_PATCHSET}\n${CAD_PATCHSET}`

git clone https://github.com/Juniper/contrail-dev-env.git
cd contrail-dev-env

# hack contrail-dev-env for our configuration/settings.
# TODO: make all of them configurable
default_interface=`ip route show | grep "default via" | awk '{print $5}'`
registry_ip=`ip address show dev $default_interface | head -3 | tail -1 | tr "/" " " | awk '{print $2}'`
sed -i -e "s/registry/${registry_ip}/g" common.env.tmpl
sed -i -e "s/contrail-registry/${registry_ip}/g" vars.yaml.tmpl
sed -i -e "s/registry/${registry_ip}/g" dev_config.yaml.tmpl
sed -i -e "s/registry/${registry_ip}/g" daemon.json.tmpl
sed -i -e "s/6666/5000/g" common.env.tmpl
sed -i -e "s/6666/5000/g" vars.yaml.tmpl
sed -i -e "s/6666/5000/g" daemon.json.tmpl
sed -i -e "s/6666/5000/g" startup.sh

sudo ./startup.sh
docker ps -a

cat >build.sh <<EOF
#!/bin/bash -ex
export OPENSTACK_VERSION=$OPENSTACK_VERSION
cd /root/contrail-dev-env
make sync
make fetch_packages
make setup

cd /root/contrail
for repoc in \`find . | grep ".git/config\$" | grep -v "\.repo"\` ; do
  repo=\`echo $repoc | rev | cut -d '/' -f 3- | rev\`
  url=\`grep "url =" \$repoc | cut -d '=' -f 2 | sed -e 's/ //g'\`
  name=\`echo \$url | rev | cut -d '/' -f 1 | rev\`
  patchset=\`echo "$full_list" | grep "/\$name "\ || /bin/true`
  if [ -n "\$patchset" ]; then
     cd $repo
     $patchset
     git pull --rebase origin master
  fi
done

cd /root/contrail-dev-env
make dep
make rpm
make containers
EOF
chmod a+x ./build.sh
docker cp ./build.sh contrail-developer-sandbox:/root/build.sh
docker exec -i contrail-developer-sandbox /root/build.sh

sudo docker images

echo "INFO: Build finished  $(date)"
