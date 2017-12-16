#!/usr/bin/env python

import sys

from charmhelpers.core.hookenv import (
    Hooks,
    UnregisteredHookError,
    config,
    log,
    related_units,
    relation_ids,
    relation_set,
)


hooks = Hooks()
config = config()


def _notify_neutron():
    for rid in relation_ids("neutron-api"):
        if related_units(rid):
            neutron_api_joined(rid)


@hooks.hook('upgrade-charm')
@hooks.hook('config-changed')
def config_changed():
    if config.changed('service-plugins'):
        _notify_neutron()


@hooks.hook("neutron-api-relation-joined")
def neutron_api_joined(rel_id=None):
    settings = {
        "neutron-plugin": "ovs",
        "service-plugins": config.get('service-plugins'),
    }
    relation_set(relation_id=rel_id, relation_settings=settings)


def main():
    try:
        hooks.execute(sys.argv)
    except UnregisteredHookError as e:
        log("Unknown hook {} - skipping.".format(e))


if __name__ == "__main__":
    main()
