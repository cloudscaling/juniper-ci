#!/bin/bash

# NOTE: current Ubuntu image has password 123 but next images should use qwe123QWE

OS="$1"

if [[ -z "$OS" ]]; then
  echo "ERROR: please run as 'prepare_image.sh {ubuntu|centos}"
  ecit 1
fi

case $OS in
  ubuntu)
    SERIES=${SERIES:-xenial}
    BASE_IMAGE_NAME="ubuntu-$SERIES.qcow2"
    wget -nv https://cloud-images.ubuntu.com/$SERIES/current/$SERIES-server-cloudimg-amd64-disk1.img -O ./$BASE_IMAGE_NAME
    ;;
  centos)
    BASE_IMAGE_NAME="centos-7_4.qcow2"
    wget -nv https://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud-1802.qcow2 -O ./$BASE_IMAGE_NAME
    ;;
  *)
    echo "ERROR: please run as 'prepare_image.sh {ubuntu|centos}"
    exit 1
    ;;
esac

# makepasswd --clearfrom=- --crypt-md5 <<< 'qwe123QWE'
# $1$PU257S1Q$hdOk0pm6Yu7URJRNLQa7e1
SSH_KEY=/home/jenkins/.ssh/id_rsa.pub

if ! lsmod |grep '^nbd ' ; then
  modprobe nbd max_part=8
fi
nbd_dev="/dev/nbd0"
qemu-nbd -d $nbd_dev || true
qemu-nbd -n -c $nbd_dev ./$BASE_IMAGE_NAME
sleep 5
ret=0
tmpdir=$(mktemp -d)
mount ${nbd_dev}p1 $tmpdir || ret=1
sleep 2

# patch image
pushd $tmpdir
# disable metadata requests
echo 'datasource_list: [ None ]' > etc/cloud/cloud.cfg.d/90_dslist.cfg
# enable root login
sed -i -e 's/^disable_root.*$/disable_root: 0/' etc/cloud/cloud.cfg
# set root password: 123
sed -i -e 's/^root:\*:/root:$1$PU257S1Q$hdOk0pm6Yu7URJRNLQa7e1:/' etc/shadow
# add ssh keys for root account
mkdir -p root/.ssh
cat $SSH_KEY > root/.ssh/authorized_keys
cat $SSH_KEY > root/.ssh/authorized_keys2
popd

umount ${nbd_dev}p1 || ret=2
sleep 2
rm -rf $tmpdir || ret=3
qemu-nbd -d $nbd_dev || ret=4
sleep 2

truncate -s 60G temp.raw
virt-resize --expand /dev/vda1 $BASE_IMAGE_NAME temp.raw
qemu-img convert -O qcow2 temp.raw $BASE_IMAGE_NAME
rm temp.raw

mv $BASE_IMAGE_NAME /var/lib/libvirt/images/
