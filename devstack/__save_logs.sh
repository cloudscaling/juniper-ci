#!/bin/bash

for u in `systemctl list-unit-files | grep devstack | awk '{print $1}'`; do
  name=$(echo $u | sed 's/devstack@/screen-/' | sed 's/\.service//')
  journalctl -o short-precise --unit $u | tee /opt/stack/logs/$name.txt > /dev/null
done
# Export the journal in export format to make it downloadable
# for later searching. It can then be rewritten to a journal native
# format locally using systemd-journal-remote. This makes a class of
# debugging much easier. We don't do the native conversion here as
# some distros do not package that tooling.
journalctl -u 'devstack@*' -o export | \
    xz --threads=0 - > /opt/stack/logs/devstack.journal.xz
# The journal contains everything running under systemd, we'll
# build an old school version of the syslog with just the
# kernel and sudo messages.
journalctl \
    -t kernel \
    -t sudo \
    --no-pager \
    --since="$(cat /opt/stack/log-start-timestamp.txt)" \
  | tee /opt/stack/logs/syslog.txt > /dev/null
