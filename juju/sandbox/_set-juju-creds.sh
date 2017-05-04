#!/bin/bash -e

ACCESS_KEY=${ACCESS_KEY:-''}
SECRET_KEY=${SECRET_KEY:-''}

juju remove-credential aws aws &>/dev/null || bin/true

cat >creds.yaml <<EOF
credentials:
  aws:
    aws:
      auth-type: access-key
      access-key: $ACCESS_KEY
      secret-key: $SECRET_KEY
EOF
juju add-credential aws -f ~/creds.yaml
region=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r ".region"`
juju set-default-region aws $region
