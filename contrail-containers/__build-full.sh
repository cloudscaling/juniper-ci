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

git clone https://github.com/Juniper/contrail-dev-env.git
cd contrail-dev-env
sudo ./startup.sh
docker ps -a

cat >build.sh <<EOF
#!/bin/bash -ex
cd /root/contrail-dev-env
make sync
make fetch_packages
make setup
make dep
make rpm
make containers
EOF
chmod a+x ./build.sh
docker cp ./build.sh contrail-developer-sandbox:/root/build.sh
docker exec -i contrail-developer-sandbox /root/build.sh

sudo docker images

echo "INFO: Build finished  $(date)"
