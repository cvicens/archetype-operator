FROM quay.io/operator-framework/ansible-operator:v0.5.0

USER root
RUN yum -y install git

ENV OC_BIN='oc-3.11.82-linux.tar.gz'
COPY ./bin/${OC_BIN} /tmp
RUN tar xzf /tmp/${OC_BIN} -C /usr/bin && chmod a+rwx /usr/bin/oc

USER ${USER_UID}
COPY roles/ ${HOME}/roles/
COPY watches.yaml ${HOME}/watches.yaml

# https://mirror.openshift.com/pub/openshift-v3/clients/ use this to get the oc bin!