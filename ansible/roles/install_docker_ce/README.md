# Ansible Role: Install Docker CE

An Ansible role to install Docker CE on Ubuntu 14.04 and above.

## Rationale for this role

For some reason, all docker-related roles that I could find in Ansible Galaxy install the `docker-engine` package, which is an outdated package. The latest Docker docs refer to the `docker-ce` package.

## Requirements

This role requires Ansible 1.2 or higher.

It only applies to Ubuntu Trusty, Xenial or Yakketty.

## Role variables

Ansible variables are listed below with their default values.

```
docker_key_url: https://download.docker.com/linux/ubuntu/gpg
docker-users:
  - "{{ ansible_ssh_user }}"
```

## Example playbook

```
---
- hosts: webservers
  roles:
  	- install_docker_ce
```

## License

MIT

