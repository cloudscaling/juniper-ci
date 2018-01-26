#!/bin/bash -e

DEBUG=${DEBUG:-0}

if (( DEBUG == 1 )) ; then set -x ; fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [ -z "$WORKSPACE" ] ; then
  export WORKSPACE="$HOME"
fi

source ${WORKSPACE}/stackrc
node_name_regexp='compute'
if [[ "$DPDK" == 'true' ]]; then
  node_name_regexp='dpdk'
elif [[ "$TSN" == 'true' ]] ; then
  node_name_regexp='tsn'
fi
for mid in `nova --insecure list | grep "$node_name_regexp" |  awk '{print $12}'` ; do
  mip="`echo $mid | cut -d '=' -f 2`"
  ssh heat-admin@$mip sudo yum install -y sshpass
done

cd $WORKSPACE
source "$my_dir/../common/openstack/functions"
create_virtualenv
access_overcloud
prep_os_checks
run_os_checks

# check Contrail WebUI
function check_ui_ip () {
  local ip="$1"
  local ret=0
  echo "INFO: check controller $ip port 8180"
  if ! curl -I  http://$ip:8180/ 2>/dev/null| grep "302" ; then
    echo "ERROR: response from port 8180 is not HTTP 302:"
    curl -I http://$ip:8180/
    local ret=1
  else
    echo "INFO: ok"
  fi
  echo "INFO: check controller $ctrl port 8143"
  local psize=`curl -I -k https://$ip:8143/ 2>/dev/null | grep "Content-Length" | cut -d ' ' -f 2 | sed 's/\r$//'`
  if (( psize < 1000 )) ; then
    echo "ERROR: response from port 8143 is smaller than 1000 bytes:"
    curl -I -k https://$ip:8143/
    local ret=1
  else
    echo "INFO: ok"
  fi
  return $ret
}

ret=0
source ${WORKSPACE}/stackrc
for ctrl in `openstack --insecure server list | grep contrailcontroller | grep -o "ctlplane=[0-9\.]*" | cut -d '=' -f 2` ; do
  check_ui_ip $ctrl || ret=1
done
ha_ip=`cat ${WORKSPACE}/overcloudrc | grep OS_AUTH_URL | grep -o "[0-9][0-9\.]*:" | cut -d ':' -f 1`
check_ui_ip $ha_ip || ret=1
exit $ret
