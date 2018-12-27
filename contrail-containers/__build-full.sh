#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

# ip is located in /usr/sbin that is not in path...
export PATH=${PATH}:/usr/sbin

linux=$(awk -F"=" '/^ID=/{print $2}' /etc/os-release | tr -d '"')

case "${linux}" in
  "ubuntu" )
    sudo apt-get update
    sudo apt-get install -y docker.io
    ;;
  "centos" | "rhel" )
    sudo yum install -y docker
    ;;
esac

echo "INFO: Start build $(date)"

git clone https://github.com/Juniper/contrail-dev-env.git
cd contrail-dev-env

# hack contrail-dev-env for our configuration/settings.
# TODO: make all of them configurable
default_interface=`ip route show | grep "default via" | awk '{print $5}'`
export REGISTRY_IP=`ip address show dev $default_interface | head -3 | tail -1 | tr "/" " " | awk '{print $2}'`
export REGISTRY_PORT=5000

sudo ./startup.sh
sudo docker ps -a

cat >build.sh <<EOF
#!/bin/bash -e
export OPENSTACK_VERSION=$OPENSTACK_VERSION
cd /root/contrail-dev-env
make sync
make fetch_packages
make setup
git config --global user.email john@google.com
cd /root/contrail
for repoc in \`find . | grep ".git/config\$" | grep -v "\.repo"\` ; do
  repo=\`echo \$repoc | rev | cut -d '/' -f 3- | rev\`
  url=\`grep "url =" \$repoc | cut -d '=' -f 2 | sed -e 's/ //g'\`
  name=\`echo \$url | rev | cut -d '/' -f 1 | rev\`
  if patchlist=\`grep "/\$name " /root/patches\` ; then
    pushd \$repo >/dev/null
    eval "\$patchlist"
    popd >/dev/nul
  fi
done

cd /root/contrail-dev-env
make dep
make rpm
make containers || /bin/true
EOF
chmod a+x ./build.sh
sudo docker cp $HOME/patches contrail-developer-sandbox:/root/patches
sudo docker cp ./build.sh contrail-developer-sandbox:/root/build.sh
sudo docker exec -i contrail-developer-sandbox /root/build.sh

sudo docker images

echo "INFO: Build finished  $(date)"
