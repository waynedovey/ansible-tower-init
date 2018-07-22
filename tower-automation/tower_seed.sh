#!/bin/bash
set -e
umask 0022
source /etc/pipeline/profile

export svcaccount=admin
export svcpass=supersecret

# Seed the Private Key for Git Access 
echo "username: ansible_tower_user" > /tmp/tower_credential_machine_input
echo "ssh_key_data: |" >> /tmp/tower_credential_machine_input
awk '{printf "  %s\n", $0}' < /var/lib/awx/.ssh/id_rsa >> /tmp/tower_credential_machine_input

# Import and Create the Git Credentials 
tower-cli credential create --name="Git" --organization="Default" --inputs=@/tmp/tower_credential_machine_input --credential-type="Source Control"
rm -fr /tmp/tower_credential_machine_input

# Create Local admin account
tower-cli credential create --name="Tower-Local-Admin" --organization="Default" --credential-type=14 --inputs='{"username": "'${svcaccount}'", "password": "'${svcpass}'", "host": "http://localhost"}'

# Project creation section start
tower-cli project create --name="OpenShift Ansible Playbooks" --description="Red Hat OCP Playbooks" --scm-type=git --scm-url="ssh://git@example.com/repo/openshift-ansible.git" --organization "Default" --scm-credential="Git" --wait
tower-cli project create --name="Ansible Tower" --description="Ansible Tower Playbooks" --scm-type=git --scm-url="ssh://git@example.com/repo/ansibletower.git" --organization "Default" --scm-credential="Git" --wait

useradd openshift
mkdir -p /home/openshift/.ssh/
chown openshift:openshift -R /home/openshift/.ssh/
chage -M -1 openshift

KEY_PASSPHRASE=""

if [ "${environmentAccount}" = "Prod" ]; then

  KEY_PASSPHRASE="$( kms_decrypt '' )"
  cp /tmp/files/ssh-keys/id_rsa.prod.openshift /home/openshift/.ssh/id_rsa

elif [ "${environmentAccount}" = "Non" ]; then

  KEY_PASSPHRASE="$( kms_decrypt '' )"
  cp /tmp/files/ssh-keys/id_rsa.non.openshift /home/openshift/.ssh/id_rsa

else
  echo "[ERROR] @KEY_PASSPHRASE [${KEY_PASSPHRASE}] unable to be set"
  return 1
fi

chmod 600 /home/openshift/.ssh/id_rsa
ssh-keygen -p -P "${KEY_PASSPHRASE}" -N '' -f /home/openshift/.ssh/id_rsa

PUBLIC_KEY=`ssh-keygen -y -f /home/openshift/.ssh/id_rsa`
echo "${PUBLIC_KEY} openshift-key" >/home/openshift/.ssh/id_rsa.pub
echo "${PUBLIC_KEY} openshift-key" >>/home/openshift/.ssh/authorized_keys

chmod 400 /home/openshift/.ssh/id_rsa
chmod 644 /home/openshift/.ssh/id_rsa.pub
chown openshift:openshift /home/openshift/.ssh/id_rsa
chown openshift:openshift /home/openshift/.ssh/id_rsa.pub
chown openshift:openshift /home/openshift/.ssh/authorized_keys

bash -c 'echo "Defaults        env_keep += \"NO_PROXY HTTP_PROXY HTTPS_PROXY no_proxy http_proxy https_proxy\"" | (EDITOR="tee -a" visudo)'
bash -c 'echo "openshift       ALL=(ALL)       NOPASSWD: ALL" | (EDITOR="tee -a" visudo)'
echo StrictHostKeyChecking no >> /etc/ssh/ssh_config


if [ "${environmentAccount}" = "Prod" ]; then

  echo "username: openshift" > /tmp/files/ssh-keys/id_rsa.prod.openshift-tower
  echo "ssh_key_unlock: ${KEY_PASSPHRASE}" >> /tmp/files/ssh-keys/id_rsa.prod.openshift-tower
  echo "become_method: sudo" >> /tmp/files/ssh-keys/id_rsa.prod.openshift-tower
  echo "ssh_key_data: |" >> /tmp/files/ssh-keys/id_rsa.prod.openshift-tower
  awk '{printf "  %s\n", $0}' < /tmp/files/ssh-keys/id_rsa.prod.openshift  >> /tmp/files/ssh-keys/id_rsa.prod.openshift-tower

  tower-cli credential create --name="OpenShift-User" -d "OpenShift Secure Remote Access" \
  --credential-type="Machine" --organization Default \
  --inputs=@/tmp/files/ssh-keys/id_rsa.prod.openshift-tower --fail-on-found

elif [ "${environmentAccount}" = "Non" ]; then

  echo "username: openshift" > /tmp/files/ssh-keys/id_rsa.non.openshift-tower
  echo "ssh_key_unlock: ${KEY_PASSPHRASE}" >> /tmp/files/ssh-keys/id_rsa.non.openshift-tower
  echo "become_method: sudo" >> /tmp/files/ssh-keys/id_rsa.non.openshift-tower
  echo "ssh_key_data: |" >> /tmp/files/ssh-keys/id_rsa.non.openshift-tower
  awk '{printf "  %s\n", $0}' < /tmp/files/ssh-keys/id_rsa.non.openshift  >> /tmp/files/ssh-keys/id_rsa.non.openshift-tower

  tower-cli credential create --name="OpenShift-User" -d "OpenShift Secure Remote Access" \
  --credential-type="Machine" --organization Default \
  --inputs=@/tmp/files/ssh-keys/id_rsa.non.openshift-tower --fail-on-found
else
  echo "[ERROR] @KEY_PASSPHRASE [${KEY_PASSPHRASE}] unable to be set"
  return 1
fi

rm -fr /tmp/files/ssh-keys/id_rsa.*

# Create Job Templates
tower-cli job_template create --name="Tower-Bootstrap-Project" \
--credential="OpenShift-User" --project="Ansible Tower" \
--playbook="pipeline/files/playbooks/bootstrap-project.yml" \
--ask-variables-on-launch="true"  \
--inventory="Tower Inventory"

tower-cli job_template associate_credential --job-template="Tower-Bootstrap-Project" --credential="Tower-Local-Admin"

tower-cli job_template create --name="Tower-Remote-Job"  \
--credential="OpenShift-User" --project="Ansible Tower" \
--playbook="pipeline/files/playbooks/tower-job-launch.yaml" \
--ask-variables-on-launch="true" \
--inventory="Tower Inventory"

tower-cli job_template associate_credential --job-template="Tower-Remote-Job" --credential="Tower-Local-Admin"

tower-cli job_template create --name="OCP-Pre-Install" --credential="OpenShift-User" \
--project="OpenShift Ansible Playbooks" --playbook="playbooks/prerequisites.yml" \
--ask-inventory-on-launch="true" --ask-variables-on-launch="true" --become-enabled="true" \
--extra-vars=@/tmp/files/openshift/ocp-template.yaml

tower-cli job_template create --name="OCP-Install" --credential="OpenShift-User" \
--project="OpenShift Ansible Playbooks" --playbook="playbooks/deploy_cluster_wrapper.yml" \
--ask-inventory-on-launch="true" --ask-variables-on-launch="true" --become-enabled="true" \
--extra-vars=@/tmp/files/openshift/ocp-template.yaml

#tower-cli job_template create --name="SOE-Pre-Install" --credential="OpenShift-User" \
#--project="OpenShift Ansible Playbooks" --playbook="playbooks/rhn-soe/rhel-soe.yaml" \
#--ask-inventory-on-launch="true" --ask-variables-on-launch="true" --become-enabled="true" \

exit 0 

# # Curl examples 
# # Create Dynamic Inventory Tower-Bootstrap-Project
#export jobtemplateid=8
export jobtemplate=Tower-Bootstrap-Project
export branch=wd
export buildnumber=472
export towerhost=tower.example.com
jobtemplateid=$(curl -s --user admin:supersecret https://${towerhost}/api/v2/job_templates/?name=${jobtemplate}| python -m json.tool | grep -m 1 id |awk -F":" '{print $2}' |awk -F"," '{print $1}' |sed 's/^[ \t]*//;s/[ \t]*$//')

curl -f -H 'Content-Type: application/json' -XPOST \
-d '{"extra_vars": "{\"branch\": \"'${branch}'\", \"buildnumber\": \"'${buildnumber}'\"}"}' \
--user admin:supersecret https://${towerhost}/api/v2/job_templates/${jobtemplateid}/launch/

# # Inventory 16 wd-471 OCP Install
# export jobtemplate=OCP-Pre-Install
#export jobtemplateid=9
export jobtemplate=Tower-Remote-Job
export branch=wd
export buildnumber=472
export jobtemplaterun=OCP-Pre-Install
export towerhost=tower.example.com
jobtemplateid=$(curl -s --user admin:supersecret https://${towerhost}/api/v2/job_templates/?name=${jobtemplate}| python -m json.tool | grep -m 1 id |awk -F":" '{print $2}' |awk -F"," '{print $1}' |sed 's/^[ \t]*//;s/[ \t]*$//')

curl -f -H 'Content-Type: application/json' -XPOST \
-d '{"extra_vars": "{\"job_template\": \"'${jobtemplaterun}'\", \"branch\": \"'${branch}'\", \"buildnumber\": \"'${buildnumber}'\"}"}' \
--user admin:supersecret https://${towerhost}/api/v2/job_templates/${jobtemplateid}/launch/

# # # Inventory 16 wd-471 OCP Install
# # export jobtemplate=OCP-Install
export jobtemplate=Tower-Remote-Job
export branch=wd
export buildnumber=472
export jobtemplaterun=OCP-Install
export towerhost=tower.example.com
jobtemplateid=$(curl -s --user admin:supersecret https://${towerhost}/api/v2/job_templates/?name=${jobtemplate}| python -m json.tool | grep -m 1 id |awk -F":" '{print $2}' |awk -F"," '{print $1}' |sed 's/^[ \t]*//;s/[ \t]*$//')

curl -f -H 'Content-Type: application/json' -XPOST \
-d '{"extra_vars": "{\"job_template\": \"'${jobtemplaterun}'\", \"branch\": \"'${branch}'\", \"buildnumber\": \"'${buildnumber}'\"}"}' \
--user admin:supersecret https://${towerhost}/api/v2/job_templates/${jobtemplateid}/launch/
