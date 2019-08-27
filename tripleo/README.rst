Overview
========

This repository provides scripts for installing TripleO with OpenContrail on host with kvm virtualization enabled.

=============
KVM Host (it is usually a jenkins slave)
- Install packages
      apt-get install -y git qemu-kvm iptables-persistent ufw virtinst uuid-runtime \
        qemu-kvm libvirt-clients libvirt-daemon-system bridge-utils virt-manager awscli python-dev hugepages gcc

      curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
      python get-pip.py 
      pip install virtualbmc

- Enable firewall with allowing ssh ports

- Prepare jenkins user to access from Jenkins master server:
      Create jenkins user with certificate authentication only
      Add the pub-key of master jenkins server into jenkins's user authorized_keys file (/home/jenkins/.ssh/authorized_keys)
```
yes | adduser --disabled-password jenkins
usermod -aG libvirt jenkins
usermod -aG docker jenkins
usermod -aG libvirt-qemu jenkins
usermod -aG kvm jenkins
su - jenkins
ssh-keygen -q

yes | adduser --disabled-password stack
usermod -aG libvirt stack
usermod -aG docker stack
usermod -aG libvirt-qemu stack
usermod -aG kvm stack
su - stack 
ssh-keygen -q
cp .ssh/id_rsa.pub .ssh/authorized_keys2
```

- configure firewall
```
ufw allow ssh
ufw allow from 192.0.0.0/8 to any
ufw allow from 10.0.0.0/8 to any
ufw allow from 172.0.0.0/8 to any
ufw enable
```
- configure hugepages
```
put the line into /etc/default/grub
GRUB_CMDLINE_LINUX="rootdelay=10 default_hugepagesz=1G hugepagesz=1G hugepages=118"
update-grub
```

- Allow ssh to skip cert-check and don't save host signatures in the known host file:
      Example of ssh config:
      cat /home/jenkins/.ssh/config
      Host *
      StrictHostKeyChecking no
      UserKnownHostsFile=/dev/null

- setup aws access for jenkins user

- Allow jenkins user to run deploy under privileged user, add to sudoers file:

  ```
  For TRIPLEO CI:
  jenkins ALL=(ALL) NOPASSWD:SETENV: /opt/jenkins/*.sh
  jenkins ALL=(ALL) NOPASSWD:SETENV: /opt/jenkins/*.sh
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

- Download  net-snmp packages
/home/jenkins/net-snmp
net-snmp-5.7.2-32.el7.x86_64.rpm             net-snmp-libs-5.7.2-32.el7.x86_64.rpm    net-snmp-utils-5.7.2-32.el7.x86_64.rpm
net-snmp-agent-libs-5.7.2-32.el7.x86_64.rpm  net-snmp-python-5.7.2-32.el7.x86_64.rpm  README

- Download images:
alexm@ns316780:~$ ls -lh /home/root/images/
total 6.5G
-rw-r--r-- 1 root root 836M May 15 12:29 centos-7_4.qcow2
lrwxrwxrwx 1 root root   18 May 15 12:36 centos.qcow2 -> ./centos-7_4.qcow2
-rw-r--r-- 1 root root 531M May 15 12:30 rhel-server-7.4-x86_64-kvm.qcow2
-rw-r--r-- 1 root root 660M May 15 12:29 rhel-server-7.5-x86_64-kvm.qcow2
-rw-r--r-- 1 root root 323M May 15 12:29 ubuntu-bionic.qcow2
-rw-r--r-- 1 root root 842M May 15 12:30 ubuntu-trusty.qcow2
-rw-r--r-- 1 root root 921M May 15 12:30 ubuntu-xenial.qcow2
-rw-r--r-- 1 root root 1.2G May 15 12:30 undercloud-rhel-7_4.qcow2
lrwxrwxrwx 1 root root   27 May 15 12:34 undercloud-rhel-7_5-newton.qcow2 -> ./undercloud-rhel-7_5.qcow2
lrwxrwxrwx 1 root root   27 May 15 12:34 undercloud-rhel-7_5-ocata.qcow2 -> ./undercloud-rhel-7_5.qcow2
-rw-r--r-- 1 root root 1.4G May 15 12:29 undercloud-rhel-7_5.qcow2
lrwxrwxrwx 1 root root   27 May 15 12:34 undercloud-rhel-7_5-queens.qcow2 -> ./undercloud-rhel-7_5.qcow2
 
- create images pool:
```
cat <<EOF > images.xml
<pool type='dir'>
  <name>images</name>
  <source>
  </source>
  <target>
    <path>/var/lib/libvirt/images</path>
    <permissions>
      <mode>0711</mode>
      <owner>0</owner>
      <group>0</group>
    </permissions>
  </target>
</pool>
EOF
virsh pool-define --file images.xml
virsh pool-autostart images
virsh pool-start images

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

For RHEL environemnt create files with appropriate rhel accounts.
Account for regular testing
```
cat <<EOF >/home/root/rhel/rhel-account
export RHEL_USER=user
export RHEL_PASSWORD=password
EOF
```

Account for rhel certification with certification rights
```
cat <<EOF > /home/root/rhel/rhel-account-cert
export RHEL_USER=user-cert
export RHEL_PASSWORD=password-cert
EOF
```


Undercloud images:
For RHEL undercloud image must be changed before usage - resize is required.
```
      # example
      export RHEL_USER=<redhat_user>
      export RHEL_PASSWORD=<redhat password>
      ./customize_rhel  /root/rhel_7_3_images_org/rhel-guest-image-7.3-36.x86_64.qcow2 \
                         /home/root/images/rhel-guest-image-7.3-36.x86_64.qcow2

      ln -s /home/root/images/rhel-guest-image-7.3-36.x86_64.qcow2 /home/root/images/undercloud-rhel-newton.qcow2
      ln -s /home/root/images/undercloud-centos7.qcow2 /home/root/images/undercloud-centos-newton.qcow2

      # structure of dir would look like this:
      ls /home/root/images/ -l
      -rw-r--r-- 1 root root  911998976 Jul 29  2016 CentOS-7-x86_64-GenericCloud-1607.qcow2
      -rw-r--r-- 1 root root 2980052992 Jul 24 19:19 undercloud-centos7.qcow2
      lrwxrwxrwx 1 root root         42 Jul 14 20:56 undercloud-centos-newton.qcow2 -> /home/root/images/undercloud-centos7.qcow2
      lrwxrwxrwx 1 root root         42 Jul 21 19:00 undercloud-centos-ocata.qcow2 -> /home/root/images/undercloud-centos7.qcow2
      lrwxrwxrwx 1 root root         46 Aug 16 08:21 undercloud-rhel-7_3-newton.qcow2 -> /home/root/images/undercloud-rhel-newton.qcow2
      lrwxrwxrwx 1 root root         45 Aug 16 08:22 undercloud-rhel-7_3-ocata.qcow2 -> /home/root/images/undercloud-rhel-ocata.qcow2
      lrwxrwxrwx 1 root root         43 Aug 16 08:21 undercloud-rhel-7_4-newton.qcow2 -> /home/root/images/undercloud-rhel-7_4.qcow2
      lrwxrwxrwx 1 root root         43 Aug 16 08:22 undercloud-rhel-7_4-ocata.qcow2 -> /home/root/images/undercloud-rhel-7_4.qcow2
      -rw-r--r-- 1 root root 1215299584 Aug 16 08:20 undercloud-rhel-7_4.qcow2
      -rw-r--r-- 1 root root 1323827200 Aug  1 16:03 undercloud-rhel-newton.qcow2
      -rw-r--r-- 1 root root 1323827200 Aug  1 16:03 undercloud-rhel-ocata.qcow2
      root@contrail-ci:~#
```
Overcloud images are customize at runtime
```
      # structure of dir would look like this:
      root@contrail-ci:~# ls -l /home/jenkins/overcloud-images
      total 8204072
      -rw-r--r-- 1 stack stack 1398367523 Jun 15 16:47 images-centos7.tar
      lrwxrwxrwx 1 stack stack         30 Jul 14 21:11 images-centos-7_3-newton.tar -> /home/jenkins/overcloud-images/images-centos7.tar
      lrwxrwxrwx 1 stack stack         30 Jul 20 17:44 images-centos-7_3-ocata.tar -> /home/jenkins/overcloud-images/images-centos7.tar
      -rw-r--r-- 1 stack stack 1741926400 Sep 21 13:45 images-rhel-7_3-newton.tar
      -rw-r--r-- 1 stack stack 1743411200 Aug  1 16:26 images-rhel-7_3-ocata.tar
      -rw-r--r-- 1 stack stack 1817180160 Sep 20 16:46 images-rhel-7_4-newton.tar
      -rw-r--r-- 1 stack stack 1700055040 Aug 16 08:43 images-rhel-7_4-ocata.tar
```


Files and parameters
====================

most of script files has definition of 'NUM' variable at start.
It allows to use several environments.

customize_rhel - to preapare images for rhel (subscribe image, set root password, etc)

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
      sudo ssh -T -i kp-$NUM -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.172.2
      su - stack
      ./overcloud-install.sh

And then last command shows deploy command that can be used in current shell or in the screen utility


Instructions was used
=====================
- https://keithtenzer.com/2015/10/14/howto-openstack-deployment-using-tripleo-and-the-red-hat-openstack-director/
- http://docs.openstack.org/developer/tripleo-docs/index.html
- https://access.redhat.com/documentation/en-US/Red_Hat_Enterprise_Linux_OpenStack_Platform/7/html/Director_Installation_and_Usage/
- http://docs.openstack.org/developer/heat/template_guide/index.html
