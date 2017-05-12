#!/bin/bash -e

rm -f apt.log
for i in {1..6} ; do
  if sudo DEBIAN_FRONTEND=noninteractive apt-get install -fy reprepro apache2 rng-tools gnupg2 &>apt.log ; then
    rm -f apt.log
    break
  fi
  sleep 20
done
if [ -f apt.log ] ; then
  cat apt.log
  exit 100
fi

# prepare packages
cdir=$(pwd)
mkdir -p /tmp/pkgs
cd /tmp/pkgs
tar xf "$cdir/contrail_debs.tgz"
cd "$cdir"

# create gpg key for repository
if ! output=`gpg2 --list-keys contrail@juniper.net` ; then
  cat >key.cfg <<EOF
    %echo Generating a basic OpenPGP key
    Key-Type: default
    Subkey-Type: ELG-E
    Subkey-Length: 1024
    Name-Real: Contrail
    Name-Comment: Contrail
    Name-Email: contrail@juniper.net
    Expire-Date: 0
    %no-protection
    %commit
    %echo done
EOF
  sudo rngd -r /dev/urandom
  gpg2 --batch --gen-key key.cfg
fi
gpg2 --export -a contrail@juniper.net > repo.key
GPGKEYID=`gpg2 --list-keys --keyid-format LONG contrail@juniper.net | grep "^pub" | awk '{print $2}' | cut -d / -f2`

# setup repository
sudo rm -rf /srv/reprepro/ubuntu
sudo mkdir -p /srv/reprepro/ubuntu/{conf,dists,incoming,indices,logs,pool,project,tmp}
cd /srv/reprepro/
sudo chmod -R a+r .
cd ubuntu
sudo chown -R `whoami` .
sudo cp "$cdir/repo.key" /srv/reprepro/ubuntu/

cat >/srv/reprepro/ubuntu/conf/distributions <<EOF
Origin: Contrail
Label: Base Contrail packages
Codename: trusty
Architectures: i386 amd64 source
Components: main
Description: Description of repository you are creating
EOF
echo "SignWith: $GPGKEYID" >> /srv/reprepro/ubuntu/conf/distributions

cat >/srv/reprepro/ubuntu/conf/options <<EOF
ask-passphrase
basedir .
EOF

for ff in `ls /tmp/pkgs/*.deb` ; do
  echo "Adding $ff"
  reprepro includedeb trusty $ff
done

cat >apt-repo.conf <<EOF
Alias /ubuntu/ "/srv/reprepro/ubuntu/"
<Directory "/srv/reprepro/ubuntu/">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
EOF
sudo cp apt-repo.conf /etc/apache2/sites-available/apt-repo.conf
if ! grep -q "apt-repo.conf" /etc/apache2/sites-available/000-default.conf ; then
  sudo sed -E -i -e "s|</VirtualHost>|        Include sites-available/apt-repo.conf\n</VirtualHost>|" /etc/apache2/sites-available/000-default.conf
fi
sudo service apache2 restart
