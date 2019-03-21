# GitOps-like kubernetes ansible operator as the gurdian of your ConfigMaps
All this started as a by-product of a meeting I had recently with a customer   and also from a conversation I had with a partner. Both events triggered the need of managing configuration in a kubernetes namespace, and because I have been invo...

Just to give you a bit of context...

The meeting with the customer was focused on new Openshift features around Ops, and most of the time was spent on [Kubernetes Operators](https://operatorhub.io/what-is-an-operator), why, how, etc. In fact it was conducted as a lab where we used the [Prometheus Operator](https://github.com/coreos/prometheus-operator), I'm referring to [this short lab](https://medium.com/devopslinks/using-the-operator-lifecycle-manager-to-deploy-prometheus-on-openshift-cd2f3abb3511). What is curious is that the relevant outcome of the meeting came from a side conversation about their CI/CD pipelines and specifically about configuration management... at that moment I thought what if we use an operator to ensure that configuration is as defined in the git repository.

The conversation with the partner happened around the same week... again a side conversation (how important is wandering aroung every now and then ;-) this time it was about creating some kind of archetype to speed up the first moves of a new project forced me to develop the operator. The key concept of the side conversation was [GitOps](https://www.weave.works/technologies/gitops/), a new concept for me that fitted perfectly with the previous conversation about configuration management.

So I decided to prove that this all made sense... and here's the result.

## TL;DR
I have developed a [Kubernetes Operator](https://operatorhub.io/what-is-an-operator) that ensures that ConfigMaps in a namespace are exactly as defined in the correspending Git repo and branch. By corresponding I mean as defined in a [Custom Resource](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/) like the next one.

**Sample Custom Resource**

> As you can see next Custom Resource of kind `Repository` points to a git repo and branch where the operator will look for ConfigMaps to later make the namespace the operator is running in match them.

```
apiVersion: cloudnative.redhat.com/v1alpha1
kind: Repository
metadata:
  name: example-repository
spec:
  # Add fields here
  gitUrl: "https://github.com/cvicens/archetype-operator-customer-service.git"
  gitRef: "master"
```

Keep reading to see how you can quickly create your own GitOps-inspired operator by taking mine as a starting point.

## Prerequisites

You need to install the Operator SDK, instructions [here](https://github.com/operator-framework/operator-sdk), section 'Prerequisites'

- [dep](https://golang.github.io/dep/docs/installation.html) version v0.5.0+.
- [git](https://git-scm.com/downloads)
- [go](https://golang.org/dl/) version v1.10+.
- [docker](https://docs.docker.com/install/) version 17.03+.
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/) version v1.11.3+ or [oc](https://docs.okd.io/latest/cli_reference/get_started_cli.html#installing-the-cli) version 3.11+
- Access to a Kubernetes v1.11.3+ or Openshift 3.11+ cluster

Because we're going to use Ansible and the k8s module to develop our operator you'll also need, Ansible and the [Openshift Python Restclient](https://github.com/openshift/openshift-restclient-python)

- pip install ansible (you may need to run this with sudo)
- pip install openshift 

> **IMPORTANT:** To run some of the tasks in this document you should be **cluster-admin** so maybe using [minishift](https://www.okd.io/minishift/) will be easier than convincing some one with super powers let you join their club ;-)

## Before we get our hands dirty. What's an Operator?

Because... I love getting my hands dirty (with code usually) but I want to know what I'm going to get them dirty with.

*An operator is, at its lowest level, a pod that will watch changes to Custom Resources that define a desired state and execute taks accordingly to ensure that the actual state matches the defined state.*

When a pod is created it specifies a service account (or uses the default service account) and is allowed to use that service account’s API credentials and referenced secrets, find more information [here](https://docs.openshift.com/container-platform/3.11/dev_guide/service_accounts.html#using-a-service-accounts-credentials-inside-a-container)

Ok, now we can get our hands dirty.

## Creating the scaffold project

*An operator is, at its lowest level, a pod that will watch changes to Custom Resources that define a desired state and execute taks accordingly to ensure that the actual state matches the defined state.*

> When a pod is created it specifies a service account (or uses the default service account) and is allowed to use that service account’s API credentials and referenced secrets, more information [here](https://docs.openshift.com/container-platform/3.11/dev_guide/service_accounts.html#using-a-service-accounts-credentials-inside-a-container)

Now let's use the Operator SDK it to create a project for our operator as follows.

> Our operator's scope (the default) is limited to a namespace, hence it is a `namespace-scoped operator`, and will watch and manage resources in a single namespace. Add `--cluster-scoped ` if the scope of your operator should be cluster-wide.

```shell
$ operator-sdk new archetype-operator --api-version=cloudnative.redhat.com/v1alpha1 --kind=Repository --type=ansible
INFO[0000] Creating new Ansible operator 'archetype-operator'. 
...
INFO[0000] Project creation complete. 
```

The next table shows the different artifacts generated in our new project folder. *Excerpt from the [operator sdk documentation](https://github.com/operator-framework/operator-sdk/blob/master/doc/ansible/project_layout.md).*

| File/Folders   | Purpose                           |
| :---           | :--- |
| deploy/ | Contains a generic set of Kubernetes manifests for deploying this operator on a Kubernetes cluster. |
| roles/<kind> | Contains an Ansible Role initialized using [Ansible Galaxy](https://docs.ansible.com/ansible/latest/reference_appendices/galaxy.html) |
| build/ | Contains scripts that the operator-sdk uses for build and initialization. |
| watches.yaml | Contains Group, Version, Kind, and Ansible invocation method. |

Some interesting elements I'd like to hightlight in folder `./deploy`.

* `operator.yaml` minimal kubernetes deployment descriptor, it needs to be modified be usable, little but important changes.
* `service_account.yaml` definition of the service account our pod will use
* `role.yaml` kubernetes role definition granting basic permissions over typical kubernetes objects, we won't change anything here because this role already provides the permissions needed regarding ConfigMaps
* `role_binding.yaml` links role and service account
* `crds` this folder contain the definition of the Custom Resource Definition (CRD) and an example of Custom Resource (CR). Take a CR as an instance of a CRD.

## Create a namespace to deploy our operator

In order to deploy our operator we need an Openshift project, so let's create one.

> '-master' is just a naming convention to refer to the git repo branch we want to sinc up ConfigMaps with. Presumably there could be other namespaces '-test', '-prod', right?

```
$ oc new-project archetype-master
or
$ kubectl new-namespace archetype-master
```

## Deploying basic artifacts

Prior to running our operator, we need to deploy some basic elements in folder `./deploy`.

> **WARNING:** In order to be able to `apply` both `deploy/role.yaml` and `deploy/crds/cloudnative_v1alpha1_repository_crd.yaml` you need to be cluster admin.
> The next command shows how to become cluster admin in an Openshift cluster
> `$ oc adm policy add-cluster-role-to-user cluster-admin <user>`

Be sure you are in the project folder...

```
$ cd archetype-operator
```

Let's deploy the definition of our Custom Resource or CRD.

```
$ oc apply -f deploy/crds/cloudnative_v1alpha1_repository_crd.yaml
or
$ kubectl apply -f deploy/crds/cloudnative_v1alpha1_repository_crd.yaml
```

Let's deploy the role we're going to grant to the operator service account and the service account itself.

```
$ oc apply -n archetype-master -f deploy/role.yaml 
or
$ kubectl apply -n archetype-master -f deploy/role.yaml 

$ oc apply -n archetype-master -f deploy/service_account.yaml 
or
$ kubectl apply -n archetype-master -f deploy/service_account.yaml 
```

Finally let's link service account with role through the role binding.

```
$ oc apply -n archetype-master -f deploy/role_binding.yaml 
or
$ kubectl apply -n archetype-master -f deploy/role_binding.yaml 
```

> *Maybe you've noticed we haven't applied `./deploy/cloudnative_v1alpha1_repository_cr.yaml`. This is becase we haven't decided yet which properties should form the spec of our Custom Resource, we'll do that later.*

## Adding actual code to our ansible role

Please go to folder `./roles/repository` and open `tasks/main.yml`, then subtitute it's contents with this.

```yaml
---
# tasks file for repository

- name: Get a list of all ConfigMap objects in namespace {{ meta.namespace }}
  k8s_facts:
    api_version: v1
    kind: ConfigMap
    namespace: '{{ meta.namespace }}'
  register: configmap_list

- name: configmap_list
  debug: 
    msg: "{{ configmap_list }}"

- name: List of configmap names in namespace {{ meta.namespace }}
  set_fact:
    configmap_names_list: "{{ configmap_list | json_query('resources[?metadata.name!=`archetype-operator-lock`].metadata.name') }}"

- name: configmap_names_list
  debug: 
    msg: "{{ configmap_names_list }}"

- name: Checking out config folder from {{ git_url }}/{{ git_ref }}
  git:
    repo: '{{ git_url }}'
    dest: ./tmp
    version: '{{ git_ref }}'

- name: Find '*-configmap' files in ./k8s folder
  find:
    paths: ./tmp/k8s
    patterns: '*-configmap.yaml'
  register: git_configmap_file_list

- name: List of configmap file paths
  set_fact:
    git_configmap_file_paths: "{{ git_configmap_file_list | json_query('files[*].path') }}"

- name: git_configmap_file_paths
  debug: 
    msg: "{{ git_configmap_file_paths }}"

- name: Get configmap content from git files
  set_fact:
    git_configmap_list: "{{ git_configmap_list | default([]) + [ item | from_yaml ] }}"
  with_file: "{{ git_configmap_file_paths }}"

- name: git_configmap_list
  debug:
    msg: "{{ git_configmap_list }}"

- name: List of configmap names from git
  set_fact:
    git_configmap_names_list: "{{ git_configmap_list | json_query('[*].metadata.name') }}"

- name: git_configmap_names_list
  debug: 
    msg: "{{ git_configmap_names_list }}"

- name: List of configmap names to delete
  set_fact:
    configmap_names_to_delete_list: "{{ configmap_names_list | difference(git_configmap_names_list) }}"

- name: configmap_names_to_delete_list
  debug: 
    msg: "{{ configmap_names_to_delete_list }}"

- name: Create configmaps from git in namespace {{ meta.namespace }}
  k8s:
    state: "{{ state }}"
    namespace: '{{ meta.namespace }}'
    definition: "{{ item }}"
    force: yes
  with_items: "{{ git_configmap_list }}"
  when: git_configmap_list is defined

- name: Delete 'to-be-deleted' configmaps from namespace {{ meta.namespace }}
  k8s:
    state: absent
    api_version: v1
    kind: ConfigMap
    namespace: '{{ meta.namespace }}'
    name: "{{ item }}"
  with_items: "{{ configmap_names_to_delete_list }}"
  when: configmap_names_to_delete_list is defined
```

What this code does is:

* Getting the a list of all ConfigMap objects in the operator's namespace and their names
* Checking out the git repo pointed by variable`git_url`
* Looking for '*-configmap' files in ./k8s folder in the cloned repo
* Creating all the ConfigMaps from the git repo in the operator's namespace
* Deleting all the ConfigMaps that shouldn't be in our namespace

> Deleting should be optional, specially in a development branch... I'll add a new variable to the Custom Resource and change the code accordingly soon

## Wait a little change to the image is needed!

As you have seen our Ansible role clones a git repo... so it needs git binary installed... so we need to install it in the image of our container. I almost forgot, we also need a python package 'jmespath' for the json_query filters.

To do this please open `./build/Dockerfile` compare it's contents and subtitute them with this.

```
FROM quay.io/operator-framework/ansible-operator:v0.5.0

USER root
RUN yum -y install git && pip install jmespath

USER ${USER_UID}
COPY roles/ ${HOME}/roles/
COPY watches.yaml ${HOME}/watches.yaml
```

## Build the image, tag it and push it
Now that the code and the Dockerfile are ready we can build the image and push it to an image registry like quay.io or docker.io.

> You can always use my image `quay.io/cvicensa/archetype-operator` if you don't have an account in a registry at hand or don't want to use it  but honestly that would take all the fun... so go and get an account somewhere, [quay.io](https://quay.io) is a nice option

Let's build the image.

> **Remember!** You should be inside the project folder

```
$ operator-sdk build archetype-operator
INFO[0000] Building Docker image archetype-operator     
Sending build context to Docker daemon  149.8MB
Step 1/6 : FROM quay.io/operator-framework/ansible-operator:v0.5.0
 ---> 1e857f3522b5
Step 2/6 : USER root
 ---> Using cache
 ---> 0e054a4cc239
Step 3/6 : RUN yum -y install git && pip install jmespath
 ---> Using cache
 ---> d5d37138b29b
Step 4/6 : USER ${USER_UID}
 ---> Running in 0ed62d3fab78
Removing intermediate container 0ed62d3fab78
 ---> fc792ae1cca8
Step 5/6 : COPY roles/ ${HOME}/roles/
 ---> 0e764654ddbc
Step 6/6 : COPY watches.yaml ${HOME}/watches.yaml
 ---> d52330d57277
Successfully built d52330d57277
Successfully tagged archetype-operator:latest
INFO[0010] Operator build complete.  
```

Let's tag the image so that we can push it later to the registry.

> If docker.io is your registry remember that tagging should be: `docker tag archetype-operator <userid>/archetype-operator`

```
$ docker tag archetype-operator quay.io/<userid>/archetype-operator
```

Finally let's push the image to the registry.

> Again if docker.io `docker push <userid>/archetype-operator`

```
$ docker push quay.io/<userid>/archetype-operator
```

## Modifying the sample Custom Resource definition

As I pointed out before, we haven't applied `./deploy/cloudnative_v1alpha1_repository_cr.yaml` yet mostly because we haven't added any meaningful properties ;-) let's fix that.

> *Remember that we create CRs to define a desired state... so we need properties to define it*

In our code we're expecting some variables: {{ state }}, {{ git_url }} and {{ git_ref }}.

Let's create a Custom Resource that matches the variables our role expects. Please open `./deploy/crds/cloudnative_v1alpha1_repository_cr.yaml` and replace section `spec` with this.

```yaml
spec:
  gitUrl: "https://github.com/cvicens/archetype-operator-customer-service.git"
  gitRef: "master"
```

> **TIP:** It's worth mentioning that variables in yaml (camel case) are translated to snake case, so `spec→gitUrl` translates to `git_url`

We should give some default values to these variables in our role, so please open file `./roles/repository/defaults/main.yml` and add these variables.

```yaml
---
# defaults file for repository
state: present
git_url: "https://github.com/cvicens/archetype-operator-customer-service.git"
git_ref: "master"
```

## Prepare the operator deployment descriptor

Please open file `./deploy/operator.yaml` and make the next changes:

* `{{ REPLACE_IMAGE }}` changes to `quay.io/<userid>/archetype-operator`
* `{{ pull_policy|default('Always') }}` changes to `Always`

> Please, take into account that `image` should point to YOUR image ;-)
 
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: archetype-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      name: archetype-operator
  template:
    metadata:
      labels:
        name: archetype-operator
    spec:
      serviceAccountName: archetype-operator
      containers:
        - name: archetype-operator
          # Replace this with the built image name
          image: "{{ REPLACE_IMAGE }}"
          imagePullPolicy: "{{ pull_policy|default('Always') }}"
          env:
            - name: WATCH_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: OPERATOR_NAME
              value: "archetype-operator"

```

Now we can deploy our operator... excited?

## Deploying our operator...

As I have aleady explained... operator == pod so we need a Deployment descriptor to actually deploy it and apply it in our namespace.

```
$ oc apply -f ./deploy/operator.yaml
or
$ kubectl apply -f ./deploy/operator.yaml
```

## Let's deploy our Custom Resource

Let's create our Custom Resource in the same namespace where we have deployed all the other resources.

```
$ oc apply -f ./deploy/crds/cloudnative_v1alpha1_repository_cr.yaml -n archetype-master
repository.cloudnative.redhat.com/example-repository created
or
$ kubectl apply -f ./deploy/crds/cloudnative_v1alpha1_repository_cr.yaml -n archetype-master
repository.cloudnative.redhat.com/example-repository created
```

Now let's have a look to the logs of our operator, but first let's locate our pod.

```
$ oc get pod
NAME                                 READY     STATUS    RESTARTS   AGE
archetype-operator-f6b778d55-w5f6m   1/1       Running   0          3m
or
$ kubectl get pod
NAME                                 READY     STATUS    RESTARTS   AGE
archetype-operator-f6b778d55-w5f6m   1/1       Running   0          3m
```

Now let's see if it all worked out properly.

```
$ oc logs archetype-operator-f6b778d55-w5f6m -n archetype-master
...
{"level":"info","ts":1553163740.4868422,"logger":"logging_event_handler","msg":"[playbook task]","name":"example-repository","namespace":"archetype-master","gvk":"cloudnative.redhat.com/v1alpha1, Kind=Repository","event_type":"playbook_on_task_start","job":"5100060361862015308","EventData.Name":"repository : Create configmaps from git in namespace archetype-master"}
{"level":"info","ts":1553163742.677012,"logger":"logging_event_handler","msg":"[playbook task]","name":"example-repository","namespace":"archetype-master","gvk":"cloudnative.redhat.com/v1alpha1, Kind=Repository","event_type":"playbook_on_task_start","job":"5100060361862015308","EventData.Name":"repository : Delete 'to-be-deleted' configmaps from namespace archetype-master"}
{"level":"info","ts":1553163742.9381266,"logger":"runner","msg":"Ansible-runner exited successfully","job":"5100060361862015308","name":"example-repository","namespace":"archetype-master"}
```

Hopefully you saw a `Ansible-runner exited successfully` so if the operator works properly there should be some ConfigMaps that weren't there before, right?

```
$ oc get configmap -n archetype-master
NAME                            DATA      AGE
archetype-operator-lock         0         11m
customer-repository-configmap   3         11m
example-repository-configmap    3         11m
```

If you clone this repo `https://github.com/cvicens/archetype-operator-customer-service.git` (the one we point to from our Custom Resource) and have a look to the contents of folder `k8s` you'll see two files that match exactly the two ConfigMaps created by the operator.

> Why don't you fork this repo and change the Custom Resource to point to your own repo, then change the contents of the ConfigMaps and see what happens...

So it works... I could stop here... but I thought it would be worth explaining how a developed locally, tested, failed and eventually made it work.

## Local testing

There are at least two ways to test our operator locally (or outside the cluster). 

The first one, supported and (potentially) easier, is explained [here](https://github.com/operator-framework/operator-sdk/blob/master/doc/ansible/user-guide.md) in topic **Run outside the cluster**. Just be sure you meet the prerequisites, change to your project folder and run `operator-sdk up local`.

If for some reason this approach doesn't work for you (id didn't to me) here's what I did:

* log in as your operator service account to your cluster
* create a test playbook that invokes our role
* run your test playbook

## The Operator runs as a service account

Let me remind you that an operator runs as a pod (in a container) where it invokes the Kubernetes/Openshift API as a certain service account. The name of this service account is set in `spec->template->spec->serviceAccount`, if not set it will be set as `default`. A file containing an API token for the pod’s service account is automatically mounted at `/var/run/secrets/kubernetes.io/serviceaccount/token`.

Next command shows that in this case the name of the service account is set to `archetype-operator`.

> Note: along with the name of the service account a token is injected to a certain mount point `/var/run/secrets/kubernetes.io/serviceaccount/token`

```
$ oc get deployment archetype-operator -o yaml -n archetype-master
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: archetype-operator
...
spec:
  ...
  template:
  ...
    spec:
      ...
      serviceAccount: archetype-operator
```

Alright, so we have the name of the service account we want to use, but before we can log in as this service account we need to get the token that is injected to the pod. Next command shows that there is a mountable secret which is also referred to as a token: `archetype-operator-token-5flc6` this is the one we need to use.

```
oc describe sa/archetype-operator
Name:         archetype-operator
Namespace:    archetype-master
Labels:       <none>
Annotations:  kubectl.kubernetes.io/last-applied-configuration={"apiVersion":"v1","kind":"ServiceAccount","metadata":{"annotations":{},"name":"archetype-operator","namespace":"archetype-master"}}

Image pull secrets:  archetype-operator-dockercfg-kgmm4
Mountable secrets:   archetype-operator-dockercfg-kgmm4
                     archetype-operator-token-5flc6
Tokens:              archetype-operator-token-5flc6
                     archetype-operator-token-mpsjz
Events:              <none>
```

Let's get the token value and log in with it.

> **Substitute with the correct secret name** this should be a **Token** and **Mountable secret**

```
$ export SA_TOKEN=$(oc get secret archetype-operator-token-5flc6 -o json | jq -r .data.token | base64 -D)
$ oc login <master_url> --token ${SA_TOKEN}
Logged into "https://master.serverless-d68e.openshiftworkshop.com:443" as "system:serviceaccount:archetype-master:archetype-operator" using the token provided.

You have one project on this server: "archetype-master"

Using project "archetype-master".
```

> You can check you're now logged in as the operator service account with this command.
> 
> ```
> $ oc whoami
> system:serviceaccount:archetype-master:archetype-operator
> ```

##  Setting up a Python virtual environment

I'm using macOS and I found that in order to meet the requirements to run my role I needed to update Python to a level macOS didn't like... so I googled my problem and hit [this](https://sourabhbajaj.com/mac-setup/Python/virtualenv.html) gem.

So the idea is to create a virtual python enviroment... bear with me and run this commands inside the project folder.

```
$ sudo pip install virtualenv
$ echo "venv/" >> .gitignore
$ source venv/bin/activate
(venv) $ pip install ansible ansible-runner ansible-runner-http openshift jmespath
```

To leave the virtual env just deactivate it...

```
$ deactivate
```

## Running our role in vacuum?

Obviously no, we need a Playbook to run our role and check if everything is alright or not. So please, create a new file call it `playbook.yaml` copy the next content in it and place it in the project folder. 

```
-
  name: Execute your roles
  hosts: localhost
  roles:
  - role: repository
    vars:
      meta:
        name: example-repository-2
        namespace: archetype-master
      git_url: "https://github.com/cvicens/archetype-operator-customer-service.git"
      git_ref: master
```

As you can see we have added a `vars` section to our role, this is to feed the role as the operatore itself does when running in the pod. Now let's test it!

```
$ ansible-playbook -i myhosts playbook.yaml
...
TASK [repository : Create configmaps from git in namespace archetype-master] **************************************************************************************
ok: [localhost] => (item={'kind': u'ConfigMap', 'data': {'key22': u'value222', 'key33': u'hey', 'key11': u'value111'}, 'apiVersion': u'v1', 'metadata': {'name': u'customer-repository-configmap'}})
ok: [localhost] => (item={'kind': u'ConfigMap', 'data': {'key6': u'value6', 'key5': u'value5xx', 'key4': u'value4xx'}, 'apiVersion': u'v1', 'metadata': {'name': u'example-repository-configmap'}})

TASK [repository : Delete 'to-be-deleted' configmaps from namespace archetype-master] *****************************************************************************

PLAY RECAP ********************************************************************************************************************************************************
localhost                  : ok=16   changed=1    unreachable=0    failed=0   
```

> Remember we're running our role with a playbook run by Ansible locally using the current logged in user (a service account) to our cluster

## Wrap up

So... we started talking about how to manage and maintain configuration in a kubernetes namespace and we ended up with an Ansible role running in a pod in the shape of an operator. Not bad!

For me the biggest take away is not being afraid to create my own Ansible Operators I hope you think the same.