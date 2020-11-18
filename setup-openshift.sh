#!/bin/bash

echo "Create OpenShift cluster"

# install-config-base.yaml
# https://cloud.redhat.com/openshift/install/metal/user-provisioned
export PULL_SECRET="pull-secret.txt"
export YAML_CONFIG_BASE="install-config-base.yaml"
export REGUSER="myuser"
export REGPASS="mypass123"
export REGAUTH=$(echo -n "$REGUSER:$REGPASS" | base64 -w0)
export REGPATH="/opt/registry/"
export BAFQDN="bastion.h6.rhaw.io"
export OCP_RELEASE="4.5.6"
export LOCAL_REGISTRY="$BAFQDN:5000"
export LOCAL_REPOSITORY="ocp4/openshift4"
export PRODUCT_REPO="openshift-release-dev"
export LOCAL_SECRET_JSON="/root/ocp4/pull-secret-local.text"
export RELEASE_NAME="ocp-release"
export ARCHITECTURE="x86_64"

if [ ! -f "$PULL_SECRET" ]
then
    echo "Missing $PULL_SECRET, please download from https://cloud.redhat.com/openshift/install/metal/user-provisioned"
    exit 1
fi
if [ ! -f "$YAML_CONFIG_BASE" ]
then
    echo "Missing $YAML_CONFIG_BASE"
    exit 1
fi

echo "Registry user: $REGUSER"
echo "Registry password: $REGPASS"
echo "Bastion host: $BAFQDN"

echo "Remove existing stuff ($REGPATH ocp4 mirror-registry)"
rm -rf $REGPATH
rm -rf ocp4
podman rm -f mirror-registry
sleep 1

echo "Create certificate in /opt/registry/"
mkdir -p $REGPATH/{auth,certs,data}
openssl req -newkey rsa:4096 -nodes -sha256 -keyout /opt/registry/certs/osreg.key -x509 -days 3650 -out /opt/registry/certs/osreg.crt -subj "/C=CH/ST=Vaud/L=Etoy/O=IBM/OU=ITS/CN=$BAFQDN"

ls -l /opt/registry/certs/osreg.key /opt/registry/certs/osreg.crt
openssl x509 -text -in /opt/registry/certs/osreg.crt | grep Subject:

echo "Create htpasswd with $REGUSER $REGPASS"
htpasswd -bBc /opt/registry/auth/htpasswd $REGUSER $REGPASS

echo "Copy certificate to /etc/pki/ca-trust/source/anchors and update trusts"
cp /opt/registry/certs/osreg.crt /etc/pki/ca-trust/source/anchors
update-ca-trust

echo "Create and start mirror-registry container"
podman run --name mirror-registry -p 5000:5000 -v /opt/registry/data:/var/lib/registry:z -v /opt/registry/auth:/auth:z -e "REGISTRY_AUTH=htpasswd" -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm" -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd -v /opt/registry/certs:/certs:z -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/osreg.crt -e REGISTRY_HTTP_TLS_KEY=/certs/osreg.key -d docker.io/library/registry:2

sleep 1
podman ps

echo "Reload firewall"
firewall-cmd --add-port=5000/tcp --zone=internal --permanent
firewall-cmd --add-port=5000/tcp --zone=public --permanent
firewall-cmd --reload

echo "Restart mirror-registry"
podman stop mirror-registry
sleep 1
podman start mirror-registry
sleep 1
podman ps

echo "Create /root/ocp4/pull-secret-local.text from pull-secret.txt with auth info for $BAFQDN:5000"
mkdir /root/ocp4
jq < $PULL_SECRET '.auths."'$BAFQDN':5000" = { email: "my@email", auth: "'$REGAUTH'" }' > /root/ocp4/pull-secret-local.text

echo "Run oc adm -a"
oc adm -a ${LOCAL_SECRET_JSON} release mirror --from=quay.io/${PRODUCT_REPO}/${RELEASE_NAME}:${OCP_RELEASE}-${ARCHITECTURE} --to=${LOCAL_REGISTRY}/${LOCAL_REPOSITORY} --to-release-image=${LOCAL_REGISTRY}/${LOCAL_REPOSITORY}:${OCP_RELEASE} --insecure=true | tee oc-adm.out

echo "Massage the yaml-file"
echo "  edit the pullSecret:"
sed < install-config-base.yaml > ocp4/install-config.yaml "s/pullSecret:.*$/pullSecret: '{\"auths\":{\"$BAFQDN:5000\": { \"auth\": \"$REGAUTH\", \"email\": \"user@domain\"}}}'/"

echo "  add the sshKey:"
sed -i -e "s/sshKey:.*$/sshKey: /" ocp4/install-config.yaml
cat ~/.ssh/id_rsa.pub >> ocp4/install-config.yaml

echo "  add the additionalTrustBundle:"
echo >> ocp4/install-config.yaml "additionalTrustBundle: |"
sed < /opt/registry/certs/osreg.crt >> ocp4/install-config.yaml "s/^/  /"

echo "  add the imageContentSources:"
echo >> ocp4/install-config.yaml "imageContentSources:"
sed >> ocp4/install-config.yaml < oc-adm.out -e '0,/repositoryDigestMirrors:/d' -e 's/^  //'

echo "Create manifests"
cd ocp4
openshift-install create manifests

echo "Turn scheduling off"
sed -i 's/true/false/' manifests/cluster-scheduler-02-config.yml

echo "Create the ignition file"
openshift-install create ignition-configs

mkdir -p /var/www/html/openshift4/$OCP_RELEASE/ignitions
cp -v *.ign /var/www/html/openshift4/$OCP_RELEASE/ignitions/
chmod 644 /var/www/html/openshift4/$OCP_RELEASE/ignitions/*.ign
restorecon -RFv /var/www/html/

echo "Installation preparation finished"
echo "Next steps:"
echo "- Install cluster nodes: /usr/local/sbin/create-ocp-cluster.sh"
echo "- Wait for master nodes to come up: Check for them with 'oc get nodes'"
echo "- Run potinstall script: /usr/local/sbin/oc-cluster-postinstall.sh"

# oc adm catalog build --appregistry-org redhat-operators --from=registry.redhat.io/openshift4/ose-operator-registry:v4.5 --to=${LOCAL_REGISTRY}/olm/redhat-operators:v1 --registry-config=${LOCAL_SECRET_JSON} --filter-by-os="linux/amd64" --insecure
# oc adm catalog mirror ${LOCAL_REGISTRY}/olm/redhat-operators:v1 ${LOCAL_REGISTRY} --registry-config=${LOCAL_SECRET_JSON} --insecure
# oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'

