# Ansible playbooks and roles for Jenkins pipelines
===

Keep inventory into ./inventory/*.yaml (pipeline can change it dynamically)
Keep variables in ./vars  (pipeline can change it dynamically)

Use include_vars in playbooks

Example:

~~~
# Creating Akraino Regional Controller EC2 instances and updating inventory and group_vars
- hosts: localhost
  vars: 
    instance_type: t2.medium
    volume_size: 8
    akraino_group: rc_host
    project_variables: "vars/akraino.yaml"
  vars_files:
    - "{{ project_variables }}"
  roles:
    - roles/akraino_deploy_ec2_instance
~~~



