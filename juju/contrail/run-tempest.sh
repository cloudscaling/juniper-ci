#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

source $my_dir/../common/functions
source $my_dir/../common/functions-openstack

USE_VENV='true'
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

auth_ip=`get_machine_ip keystone`

create_stackrc
source $WORKSPACE/stackrc

create_virtualenv
image_id=`create_image`
image_id_alt=`create_image cirros_alt`
create_flavors

activate_venv
network_id=`openstack network list --external -c ID -f value | head -1`
openstack role create Member || /bin/true
api_ext=`openstack extension list --network -c Alias -f value | tr '\n' ','`

if ! openstack project show demo1 ; then
  openstack project create demo1
  openstack user create --project demo1 --password password demo1
fi
if ! openstack project show demo2 ; then
  openstack project create demo2
  openstack user create --project demo2 --password password demo2
fi
deactivate_venv

cd $WORKSPACE/tempest
rm -f *.xml

CONF="$(pwd)/etc/tempest.conf"
cp $my_dir/tempest/tempest.conf $CONF
sed -i "s/%AUTH_IP%/$auth_ip/g" $CONF
sed -i "s|%TEMPEST_DIR%|$(pwd)|g" $CONF
sed -i "s/%IMAGE_ID%/$image_id/g" $CONF
sed -i "s/%IMAGE_ID_ALT%/$image_id_alt/g" $CONF
sed -i "s/%NETWORK_ID%/$network_id/g" $CONF
sed -i "s/%API_EXT%/$api_ext/g" $CONF

activate_venv
pip install -r requirements.txt
pip install junitxml

tests=$(mktemp)
tests_regex="(tempest\.api\.network)"
python -m testtools.run discover -t ./ ./tempest/test_discover --list | grep -P "$tests_regex" > $tests
tests_filtered=$(mktemp)
python $my_dir/tempest/format_test_list.py $my_dir/tempest excludes.$VERSION $tests > $tests_filtered

export OS_TEST_TIMEOUT=700
[ -d .testrepository ] || testr init

set +e
#python -m subunit.run discover -t ./ ./tempest/test_discover --load-list=$tests_filtered | subunit-trace -n -f
testr run --subunit --parallel --concurrency=2 --load-list=$tests_filtered | subunit-trace -n -f
exit_code=$?

testr last --subunit | subunit-1to2 | python "$my_dir/../../tempest/subunit2jenkins.py" -o test_result.xml -s scaleio-openstack

deactivate_venv

cd $my_dir

rm -f $tests $tests_filtered

exit $exit_code
