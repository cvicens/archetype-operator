#!/bin/bash

# Environment
. ./0-environment.sh

# add the location of minishift executable to PATH
# I also keep other handy tools like kubectl and kubetail.sh
# in that directory

minishift profile set ${MINISHIFT_PROFILE}
minishift config set memory ${MINISHIFT_MEMORY}
minishift config set cpus ${MINISHIFT_CPUS}
minishift config set vm-driver ${MINISHIFT_VM_DRIVER} ## or virtualbox, or kvm, for Fedora
minishift config set disk-size ${MINISHIFT_DISK_SIZE} # extra disk size for the vm
minishift config set image-caching true
minishift addon enable admin-user
minishift addon disable anyuid
minishift addon disable xpaas

minishift start --skip-startup-checks --skip-registration; sleep 10; minishift addon apply anyuid

minishift ssh -- sudo setenforce 0

eval $(minishift oc-env)
eval $(minishift docker-env)

oc login $(minishift ip):8443 -u admin -p admin


