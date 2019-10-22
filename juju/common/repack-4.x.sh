#!/bin/bash -e

path="$1"
ext="$2"

if [[ -z "$path" || -z "$ext" ]] ; then
  echo "command to run: $0 path_to_artifacts archive_suffix"
  echo "repack.sh /auto/github-build/R4.0/30/ubuntu-14-04/mitaka/artifacts 30-mitaka"
  exit 1
fi

function unpack() {
  local f=`ls $1`
  echo "unpack $f"
  tar -xf $f
}

rm -rf pkgs
mkdir -p pkgs
cd pkgs
unpack "$path/contrail-networking-thirdparty_*.tgz"
unpack "$path/contrail-neutron-plugin-packages_*.tgz"
unpack "$path/contrail-openstack-packages_*tgz"
unpack "$path/contrail-vrouter-packages_*tgz"

bn="contrail_debs-${ext}"
tar -cf ../${bn}.tar .
cd ..
gzip ${bn}.tar
mv ${bn}.tar.gz ${bn}.tgz
rm -rf pkgs
ls -lh ${bn}*
