#!/bin/bash -e

export OS_AUTH_URL=http://$auth_ip:5000/v2.0
export OS_USERNAME=admin
export OS_TENANT_NAME=admin
export OS_PROJECT_NAME=admin
export OS_PASSWORD=password

for (( i=1; i<9; ++i )) ; do
  if ! keystone tenant-get test_tenant_$i &>/dev/null ; then
    keystone tenant-create --name test_tenant_$i 2>/dev/null
  fi
  if ! keystone user-get user_$i &>/dev/null ; then
    keystone user-create --name user_$i --tenant test_tenant_$i --pass password 2>/dev/null
    if (( i>=5 )) ; then
      keystone user-role-add --tenant test_tenant_$i --user user_$i --role Admin 2>/dev/null
    fi
  fi
done
