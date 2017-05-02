#!/bin/bash -e

sudo DEBIAN_FRONTEND=noninteractive apt-get install -fy reprepro apache2 rng-tools

# prepare packages
cdir=$(pwd)
mkdir -p /tmp/pkgs
cd /tmp/pkgs
tar xf "$cdir/contrail_debs.tgz"
cd "$cdir"

# create gpg key for repository
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
gpg2 --export -a contrail@juniper.net > repo.key
GPGKEYID=`gpg2 --list-keys --keyid-format LONG contrail@juniper.net | grep "^pub" | awk '{print $2}' | cut -d / -f2`

# setup repository
sudo mkdir -p /srv/reprepro/ubuntu/{conf,dists,incoming,indices,logs,pool,project,tmp}
cd /srv/reprepro/
sudo chmod -R a+r .
cd ubuntu
sudo chown -R `whoami` .
sudo cp "$cdir/repo.key" /srv/reprepro/

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

cat >000-default.conf <<EOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /srv/reprepro
    <Directory /srv/reprepro>
	Options Indexes FollowSymLinks
	AllowOverride None
	Require all granted
    </Directory>

    LogLevel debug
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF
sudo cp 000-default.conf /etc/apache2/sites-available/000-default.conf
sudo service apache2 restart
