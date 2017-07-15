Overview
========

This repository provides scripts for installing TripleO with OpenContrail on host with kvm virtualization enabled.

=============
KVM Host (it is usually a jenkins slave)
- Install packages
      apt-get install -y git qemu-kvm iptables-persistent ufw virtinst uuid-runtime

- Enable firewall with allowing ssh ports

- Prepare jenkins user to access from Jenkins master server:
      Create jenkins user with certificate authentication only
      Add the pub-key of master jenkins server into jenkins's user authorized_keys file (/home/jenkins/.ssh/authorized_keys)

- Allow ssh to skip cert-check and don't save host signatures in the known host file:
      Example of ssh config:
      cat /home/jenkins/.ssh/config
      Host *
      StrictHostKeyChecking no
      UserKnownHostsFile=/dev/null

- Allow jenkins user to run deploy under privileged user, add to sudoers file:

  ```
  For TRIPLEO CI:
  jenkins ALL=(ALL) NOPASSWD:SETENV: /opt/jenkins/deploy_all.sh
  jenkins ALL=(ALL) NOPASSWD:SETENV: /opt/jenkins/clean_env.sh
  ```
  These scripts should point to jenkins scripts in a worskace.
  Example:
  ```
      root@contrail-ci:~# ls  /opt/jenkins/
      tripleo_contrail_clean_env.sh  tripleo_contrail_deploy_all.sh

      root@contrail-ci:~# cat /opt/jenkins/tripleo_contrail_deploy_all.sh
      #!/bin/bash -ex

      dir=$WORKSPACE/juniper-ci/tripleo
      ${dir}/deploy_all.sh ${dir}/check-contrail-proxy.sh
      root@contrail-ci:~# ls  /opt/jenkins/
      tripleo_contrail_clean_env.sh  tripleo_contrail_deploy_all.sh
      root@contrail-ci:~# cat /opt/jenkins/tripleo_contrail_deploy_all.sh
      #!/bin/bash -ex

      dir=$WORKSPACE/juniper-ci/tripleo
      ${dir}/deploy_all.sh ${dir}/check-contrail-proxy.sh
      root@contrail-ci:~# cat /opt/jenkins/tripleo_contrail_clean_env.sh
      #!/bin/bash -ex
      dir=$WORKSPACE/juniper-ci/tripleo
      ${dir}/clean_env.sh
```

- On the Jenkins master add new builder, with options:
  * limit number of executor processess with reasonable number, e.g. 3 for the server with 128GB RAM, 32 logical CPUs and a RAID on 2 SSD disks.
  * root of remote filesystem: /home/jenkins
  * the way to run jenkins slave agent: Launch jenkins via execution of command on the master:
    ssh -v jenkins@158.69.124.47 'cd ~ && wget http://52.15.65.240:8080/jnlpJars/slave.jar && java -jar ~/slave.jar'
    (put your real IP/name of jenkins slave server)
    In unknown reason the the other ways didn't work in our case.

- Check that user 'stack' exists on the kvm host and he has home directory, and he is added to libvirt group

- Checkout this project

Images
======
Undercloud images:
For RHEL undercloud image must be changed before usage, RHEL subscription is requried.
```
      cd /home/root/images
      export LIBGUESTFS_BACKEND=direct
      qemu-img create -f qcow2 undercloud-rhel-image.qcow2 100G
      virt-resize --expand /dev/sda1 rhel-guest-image-7.3-36.x86_64.qcow2 undercloud-rhel-image.qcow2
      virt-customize -a undercloud-rhel-image.qcow2 --root-password password:qwe123QWE
      virt-customize -a undercloud-rhel-image.qcow2 \
            --run-command 'xfs_growfs /' \
            --sm-credentials <your_rhel_user>:password:<your_rhel_password> --sm-register --sm-attach auto \
            --run-command 'subscription-manager repos --enable=rhel-7-server-rpms --enable=rhel-7-server-extras-rpms --enable=rhel-7-server-rh-common-rpms --enable=rhel-ha-for-rhel-7-server-rpms --enable=rhel-7-server-openstack-10-rpms' \
            --run-command 'sed -i "s/PasswordAuthentication no/PasswordAuthentication yes/g" /etc/ssh/sshd_config' \
            --run-command 'systemctl enable sshd' \
            --run-command 'yum remove -y cloud-init' \
            --selinux-relabel

      ln -s /home/root/images/undercloud-rhel-image.qcow2 undercloud-rhel.qcow2
      ln -s /home/root/images/undercloud-centos7.qcow2 undercloud-centos.qcow2

      ls -lh /home/root/images/
      -rw-r--r-- 1 root root 561M Jul 14 21:06 rhel-guest-image-7.3-36.x86_64.qcow2
      -rw-r--r-- 1 root root 2.8G Mar 11 13:20 undercloud-centos7.qcow2
      lrwxrwxrwx 1 root root   42 Jul 14 20:56 undercloud-centos.qcow2 -> /home/root/images/undercloud-centos7.qcow2
      lrwxrwxrwx 1 root root   54 Jul 14 20:56 undercloud-rhel.qcow2 -> /home/root/images/undercloud-rhel-image.qcow2
```
Overcloud image: for debug purposes set root password via
```
      virt-customize -a overcloud-full.qcow2 --root-password password:qwe123QWE
```
and re-create archive with images.
Overcloud image archive:
```
      root@contrail-ci:~# ls -lh /home/stack/
      -rw-r--r-- 1 stack stack 1.4G Jun 15 16:47 images-centos7.tar
      lrwxrwxrwx 1 stack stack   30 Jul 14 21:11 images-centos-newton.tar -> /home/stack/images-centos7.tar
      -rw-r--r-- 1 stack stack 1.6G Jul 14 15:31 images-rhel73.tar
      lrwxrwxrwx 1 stack stack   29 Jul 14 21:11 images-rhel-newton.tar -> /home/stack/images-rhel73.tar
```

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
