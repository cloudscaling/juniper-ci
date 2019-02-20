#!/bin/bash -e

DEBUG=${DEBUG:-0}

if (( DEBUG == 1 )) ; then set -x ; fi

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [ -z "$WORKSPACE" ] ; then
  export WORKSPACE="$HOME"
fi

export OVERCLOUD_TLS_OPTS=""
export INTROSPECT_CURL_OPTS=""
export INTROSPECT_CURL_PROTO="http"

SERVER_CA_CERTFILE_DEFAULT='/etc/contrail/ssl/certs/ca-cert.pem'
[[ "$FREE_IPA" == 'true' ]] && SERVER_CA_CERTFILE_DEFAULT='/etc/ipa/ca.crt'

export SERVER_KEYFILE=${SERVER_KEYFILE:-'/etc/contrail/ssl/private/server-privkey.pem'}
export SERVER_CERTFILE=${SERVER_CERTFILE:-'/etc/contrail/ssl/certs/server.pem'}
export SERVER_CA_CERTFILE=${SERVER_CA_CERTFILE:-${SERVER_CA_CERTFILE_DEFAULT}}

if [[ "$TLS" != 'off' ]] ; then
  OVERCLOUD_TLS_OPTS="--insecure"
  if [[ -f /home/stack/ca.crt.pem && -f /home/stack/server.crt.pem && -f /home/stack/server.key.pem ]] ; then
    # export OS_CACERT='/home/stack/ca.crt.pem'
    # export OS_CERT='/home/stack/server.crt.pem'
    # export OS_KEY='/home/stack/server.key.pem'
    OVERCLOUD_TLS_OPTS=" --os-cacert /home/stack/ca.crt.pem"
    OVERCLOUD_TLS_OPTS+=" --os-cert /home/stack/server.crt.pem"
    OVERCLOUD_TLS_OPTS+=" --os-key /home/stack/server.key.pem"
  fi

  INTROSPECT_CURL_OPTS="--key ${SERVER_KEYFILE} --cert ${SERVER_CERTFILE} --cacert ${SERVER_CA_CERTFILE}"
  INTROSPECT_CURL_PROTO="https"
fi

source ${WORKSPACE}/stackrc
node_name_regexp='compute'
if [[ "$DPDK" != 'off' ]]; then
  node_name_regexp='dpdk'
elif [[ "$TSN" == 'true' ]] ; then
  node_name_regexp='tsn'
fi
# tls note: undercloud is w/o tls
for mid in `nova list | grep "$node_name_regexp" |  awk '{print $12}'` ; do
  mip="`echo $mid | cut -d '=' -f 2`"
  ssh heat-admin@$mip sudo yum install -y sshpass
done

ret=0

cd $WORKSPACE
source "$my_dir/../common/openstack/functions"
create_virtualenv || ret=1
access_overcloud || ret=1
prep_os_checks || ret=1
run_os_checks || ret=1

# check Contrail WebUI
function check_ui_ip () {
  local ip="$1"
  local ret=0
  if [[ 'newton|ocata|pike' =~ $OPENSTACK_VERSION  ]] ; then
    if [[ "$TLS" == 'off' ]] ; then
      echo "INFO: check controller $ip port 8180"
      if ! curl -I  http://$ip:8180/ 2>/dev/null| grep "302" ; then
        echo "ERROR: response from port 8180 is not HTTP 302:"
        curl -I http://$ip:8180/ || true
        ret=1
      else
        echo "INFO: ok"
      fi
    else
      echo "WARN: TODO: skip checking 8180 port in TLS mode, it fails."
    fi
  else
      echo "WARN: TODO: skip checking 8180 port in queens, it is not exported."
  fi

  echo "INFO: check controller $ctrl port 8143"
  local psize=`curl -I -k https://$ip:8143/ 2>/dev/null | grep "Content-Length" | cut -d ' ' -f 2 | sed 's/\r$//'`
  if (( psize < 1000 )) ; then
    echo "ERROR: response from port 8143 is smaller than 1000 bytes:"
    curl -I -k https://$ip:8143/
    ret=1
  else
    echo "INFO: ok"
  fi
  return $ret
}

source ${WORKSPACE}/stackrc
# tls note: undercloud is w/o tls
for ctrl in `openstack server list | grep 'contrailcontroller-' | grep -o "ctlplane=[0-9\.]*" | cut -d '=' -f 2` ; do
  check_ui_ip $ctrl || ret=1
done
ha_ip=`cat ${WORKSPACE}/overcloudrc | grep OS_AUTH_URL | grep -o "http[s]*:[^:]*" | cut -d '/' -f 3`
check_ui_ip $ha_ip || ret=1
exit $ret

