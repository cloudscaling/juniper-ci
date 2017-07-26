#!/bin/bash

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

rm -f *.xml
source .venv/bin/activate
pip install junitxml
pip install google-api-python-client

export OS_TEST_TIMEOUT=3600
[ -d .testrepository ] || testr init
testr run --subunit $1 | subunit-trace -n -f
exit_status=$?

suite=`basename "$(readlink -f ..)"`
testr last --subunit | subunit-1to2 | python "$my_dir/subunit2jenkins.py" -o test_result.xml -s $suite

deactivate

exit $exit_status
