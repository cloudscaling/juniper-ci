#!/bin/bash -e

cd tempest
python -m virtualenv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..

if [ -d ec2-api ] ; then
  cd ec2-api
  pip install -r requirements.txt
  python setup.py install
  cd ..
fi

if [ -d gce-api ] ; then
  cd gce-api
  pip install -r requirements.txt
  python setup.py install
  cd ..
fi
