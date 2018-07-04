#!/bin/bash -e

DEBUG=${DEBUG:-0}

if (( DEBUG == 1 )) ; then set -x ; fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [ -z "$WORKSPACE" ] ; then
  export WORKSPACE="$HOME"
fi

export OS_TLS_OPTS=""
if [[ "$TLS" != 'off' ]] ; then
  OS_TLS_OPTS="--insecure"
  if [[ -f /home/stack/ca.crt.pem && -f /home/stack/server.crt.pem && -f /home/stack/server.key.pem ]] ; then
    # export OS_CACERT='/home/stack/ca.crt.pem'
    # export OS_CERT='/home/stack/server.crt.pem'
    # export OS_KEY='/home/stack/server.key.pem'
    OS_TLS_OPTS=" --os-cacert /home/stack/ca.crt.pem"
    OS_TLS_OPTS+=" --os-cert /home/stack/server.crt.pem"
    OS_TLS_OPTS+=" --os-key /home/stack/server.key.pem"
  fi
fi

source ${WORKSPACE}/stackrc
node_name_regexp='compute'
if [[ "$DPDK" == 'true' ]]; then
  node_name_regexp='dpdk'
elif [[ "$TSN" == 'true' ]] ; then
  node_name_regexp='tsn'
fi
# tls note: undercloud is w/o tls
for mid in `nova list | grep "$node_name_regexp" |  awk '{print $12}'` ; do
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
  if [[ "$TLS" == 'off' ]] ; then
    echo "INFO: check controller $ip port 8180"
    if ! curl -I  http://$ip:8180/ 2>/dev/null| grep "302" ; then
      echo "ERROR: response from port 8180 is not HTTP 302:"
      curl -I http://$ip:8180/ || true
      local ret=1
    else
      echo "INFO: ok"
    fi
  else
    echo "WARN: TODO: skip checking 8180 port in TLS mode, it fails."
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
# tls note: undercloud is w/o tls
for ctrl in `openstack server list | grep contrailcontroller | grep -o "ctlplane=[0-9\.]*" | cut -d '=' -f 2` ; do
  check_ui_ip $ctrl || ret=1
done
ha_ip=`cat ${WORKSPACE}/overcloudrc | grep OS_AUTH_URL | grep -o "[0-9][0-9\.]*:" | cut -d ':' -f 1`
check_ui_ip $ha_ip || ret=1
exit $ret
