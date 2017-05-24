Overview
========

This repository provides scripts for installing TripleO with OpenContrail on host with kvm virtualization enabled.


Prepare steps
=============

- check that user 'stack' exists on the kvm host and he has home directory, and he is added to libvirtd group
- checkout this project


Files and parameters
====================

most of script files has definition of 'NUM' variable at start.
It allows to use several environments.

create_env.sh - creates machines/networks/volumes on host regarding to 'NUM' environment variable. Also it defines machines counts for each role.

clean_env.sh - removes all for 'NUM' environment.

undercloud-install.sh - installs undercloud on the undercloud machine. This script (and sub-scripts) uses simplpe CentOS cloud image for building undercloud. Script patches this image to be able to ssh into it and run the image with QEMU. Then script logins (via ssh) into the VM and adds standard delorean repos. Then script installs undercloud by command 'openstack undercloud install' and TripleO does all work for installing needed software and generates/uploads images for overcloud. After these steps we have standard undercloud deployment. But also this script patches some TripleO files for correct work of next steps.

overcloud-install.sh - installs overcloud


Install steps
=============

   .. code-block:: console

      # set number of environment (from 0 to 6)
      export NUM=0
      # set version of OpenStack (starting from mitaka)
      export OPENSTACK_VERSION='mitaka'
      # and run
      sudo ./create_env.sh
      sudo ./undercloud-install.sh
      # address depends on NUM varaible. check previous output for exact address
      sudo ssh -t -i kp-$NUM -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.172.2
      su - stack
      ./overcloud-install.sh

And then last command shows deploy command that can be used in current shell or in the screen utility


Instructions was used
=====================
- https://keithtenzer.com/2015/10/14/howto-openstack-deployment-using-tripleo-and-the-red-hat-openstack-director/
- http://docs.openstack.org/developer/tripleo-docs/index.html
- https://access.redhat.com/documentation/en-US/Red_Hat_Enterprise_Linux_OpenStack_Platform/7/html/Director_Installation_and_Usage/
- http://docs.openstack.org/developer/heat/template_guide/index.html
