#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname ${my_file})"

export WORKING_DIR=${WORKING_DIR:-'./'}

export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-''}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-''}
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r ".region"`}

cd ${WORKING_DIR}

wget https://bootstrap.pypa.io/get-pip.py
sudo python get-pip.py
sudo pip install virtualenv

if [[ ! -d '.env' ]] ; then
    virtualenv .venv
fi
source .venv/bin/activate

pip_modules=('python-openstackclient' 'awscli' 'botocore' 'twisted')

for m in ${pip_modules[@]}; do
    pip install $m
done

juju remove-credential aws aws &>/dev/null || /bin/true

creds_file="/tmp/creds.yaml"
cat >"$creds_file" <<EOF
credentials:
  aws:
    aws:
      auth-type: access-key
      access-key: $AWS_ACCESS_KEY_ID
      secret-key: $AWS_SECRET_ACCESS_KEY
EOF
juju add-credential aws -f "$creds_file"
rm -f "$creds_file"
juju set-default-region aws ${AWS_DEFAULT_REGION}


${my_dir}/listen-contrail-events.sh
