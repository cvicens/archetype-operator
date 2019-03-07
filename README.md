operator-sdk new archetype-operator --api-version=cloudnative.redhat.com/v1alpha1 --kind=Repository --type=ansible

cd archetype-operator

oc new-project archetype-master

oc apply -f deploy/crds/cloudnative_v1alpha1_repository_crd.yaml

oc apply -f deploy/service_account.yaml 
oc apply -f deploy/role.yaml 
oc apply -f deploy/role_binding.yaml 

ln -s  $(pwd)/roles/repository/ /opt/ansible/roles/repository



# build and push
operator-sdk build archetype-operator && docker tag archetype-operator cvicens/archetype-operator && docker push cvicens/archetype-operator


##### python virtual env
https://sourabhbajaj.com/mac-setup/Python/virtualenv.html

sudo pip install virtualenv
echo "venv/" >> .gitignore

source venv/bin/activate
(venv) $ pip install ansible ansible-runner ansible-runner-http openshift

# Local testing...
ansible-playbook -i myhosts playbook.yaml --extra-vars='{"meta":{"name":"example-repository-2", "namespace":"archetype-master"},"git_url":"https://github.com/cvicens/archetype-operator-customer-service.git", "git_ref":"master"}'

# More local testing... fails...
operator-sdk up local