#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source $my_dir/functions
source $my_dir/functions-openstack

trap 'catch_errors_ce $LINENO' ERR EXIT
function catch_errors_ce() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  exit $exit_code
}

VERSION=${VERSION:-"XXX-mitaka"}
VERSION=${VERSION#*-}

# official tempest version for mitaka
case "$VERSION" in
  "mitaka")
    tver="13.0.0"
    ;;
  "newton")
    tver="13.0.0"
    ;;
  "ocata")
    tver="15.0.0"
    ;;
  *)
    tver=""
    ;;
esac
if [[ -n "$tver" ]]; then
  pushd "$WORKSPACE/tempest"
  git checkout tags/$tver
  popd
fi

if [[ "$USE_SSL_OS" == "true" ]] ; then
  export OS_CACERT="$WORKSPACE/ssl/rootCA.pem"
fi

create_stackrc
source $WORKSPACE/stackrc

echo "INFO: Check/create images"
create_virtualenv
image_id=`create_image`
image_id_alt=`create_image cirros_alt`
create_flavors

activate_venv
echo "INFO: Get external network"
network_id=`openstack network list --external -c ID -f value | head -1`
echo "INFO: Create 'Member' role for unknown reason"
openstack role create Member || /bin/true
echo "INFO: Get network api extensions"
api_ext=`openstack extension list --network -c Alias -f value | tr '\n' ','`

if ! openstack project show demo1 &>/dev/null ; then
  echo "INFO: Creating project/user: demo1/demo1"
  openstack project create demo1
  openstack user create --project demo1 --password password demo1
fi
if ! openstack project show demo2 &>/dev/null ; then
  echo "INFO: Creating project/user: demo2/demo2"
  openstack project create demo2
  openstack user create --project demo2 --password password demo2
fi
deactivate_venv

cd $WORKSPACE/tempest
rm -f *.xml

echo "INFO: Prepare tempest.conf"
CONF="$(pwd)/etc/tempest.conf"
cp $my_dir/tempest/tempest.conf $CONF
sed -i "s|%OS_AUTH_URL%|$OS_AUTH_URL|g" $CONF
sed -i "s|%OS_AUTH_VER%|$OS_IDENTITY_API_VERSION|g" $CONF
sed -i "s|%CAFILE%|$OS_CACERT|g" $CONF
sed -i "s|%TEMPEST_DIR%|$(pwd)|g" $CONF
sed -i "s/%IMAGE_ID%/$image_id/g" $CONF
sed -i "s/%IMAGE_ID_ALT%/$image_id_alt/g" $CONF
sed -i "s/%NETWORK_ID%/$network_id/g" $CONF
sed -i "s/%API_EXT%/$api_ext/g" $CONF

echo "INFO: Prepare tempest requirements"
activate_venv
pip install -r requirements.txt
pip install junitxml

echo "INFO: Prepare tests list"
tests=$(mktemp)
tests_regex="(tempest\.api\.network)"
python -m testtools.run discover -t ./ ./tempest/test_discover --list | grep -P "$tests_regex" > $tests
tests_filtered=$(mktemp)
python $my_dir/tempest/format_test_list.py $my_dir/tempest excludes.$VERSION $tests > $tests_filtered

echo "INFO: Init testr"
export OS_TEST_TIMEOUT=700
[ -d .testrepository ] || testr init

set +e
trap - ERR EXIT

echo "INFO: Run tempest tests"
testr run --subunit --parallel --concurrency=2 --load-list=$tests_filtered | subunit-trace -n -f
echo "INFO: Convert results"
testr last --subunit | subunit-1to2 | python "$my_dir/../../tempest/subunit2jenkins.py" -o test_result.xml -s scaleio-openstack
rm -f $tests $tests_filtered
deactivate_venv

cd $my_dir
