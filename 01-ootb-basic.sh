#!/bin/bash

kube_context=$1

source_registry_hostname=$2 #registry.tanzu.vmware.com
source_registry_username=$3 #pivnet username
source_registry_password=$4 #pivnet password

target_registry_hostname=$5 #ex. tanzuapplicationregistry.azurecr.io
target_registry_username=$6 #ex. tanzuapplicationregistry
target_registry_password=$7

full_domain=$8 #full.tap.<domain-name>.com
gitops_repo=$9 #git@github.com:<org>/tap-gitops.git
git_catalog_repository=$10 #https://github.com/nycpivot/tanzu-application-platform/catalog-info.yaml


export IMGPKG_REGISTRY_HOSTNAME_0=$source_registry_hostname
export IMGPKG_REGISTRY_USERNAME_0=$source_registry_username
export IMGPKG_REGISTRY_PASSWORD_0=$source_registry_password
export IMGPKG_REGISTRY_HOSTNAME_1=$target_registry_hostname
export IMGPKG_REGISTRY_USERNAME_1=$target_registry_username
export IMGPKG_REGISTRY_PASSWORD_1=$target_registry_password

export INSTALL_REGISTRY_HOSTNAME=$source_registry_hostname
export INSTALL_REGISTRY_USERNAME=$source_registry_username
export INSTALL_REGISTRY_PASSWORD=$source_registry_password

kubectl config use-context $kube_context
echo

#PREREQS
rm sops
wget https://github.com/mozilla/sops/releases/download/v3.7.3/sops-v3.7.3.linux.amd64 -O sops
chmod 777 sops

sudo apt install age


# 1. GET PIVNET ACCESS TOKEN
token=$(curl -X POST https://network.pivotal.io/api/v2/authentication/access_tokens -d '{"refresh_token":"'$PIVNET_TOKEN'"}')
access_token=$(echo $token | jq -r .access_token)

curl -i -H "Accept: application/json" -H "Content-Type: application/json" -H "Authorization: Bearer $access_token" -X GET https://network.pivotal.io/api/v2/authentication


#DELETE AND CREATE GITOPS REPO
#gh auth refresh -h github.com -s delete_repo
#gh repo delete tap-gitops --confirm

rm .ssh/id_ed25519
rm .ssh/id_ed25519.pub
ssh-keygen -t ed25519 -C "ssh@github.com"

#gh repo create tap-gitops --public
#gh repo deploy-key add ~/.ssh/tap-gitops.pub

#copy public key into github deploy-key
cat .ssh/id_ed25519.pub

echo
read -p "Copy above key into new or existing github repo deploy-key (press Enter when done): " fake_wait_prompt

git clone $gitops_repo

wget https://network.tanzu.vmware.com/api/v2/products/tanzu-application-platform/releases/1283005/product_files/1467377/download --header="Authorization: Bearer $access_token" -O $HOME/tanzu-gitops-ri-0.1.0.tgz
tar xvf tanzu-gitops-ri-0.1.0.tgz -C $HOME/tap-gitops

rm tanzu-gitops-ri-0.1.0.tgz

cd $HOME/tap-gitops

git add .
git commit -m "Initialize Tanzu GitOps RI"
git push -u origin main


#CREATE CLUSTER CONFIG
./setup-repo.sh $kube_context sops

git add .
git commit -m "Added tap-full cluster"
git push

cd $HOME

#SETUP AGE
age-keygen -o key.txt

export SOPS_AGE_KEY_FILE=key.txt

cat <<EOF | tee tap-sensitive-values.yaml
tap_install:
 sensitive_values:
EOF

export SOPS_AGE_RECIPIENTS=$(cat $HOME/key.txt | grep "# public key: " | sed 's/# public key: //')
./sops --encrypt $HOME/tap-sensitive-values.yaml > $HOME/tap-sensitive-values.sops.yaml

mv $HOME/tap-sensitive-values.sops.yaml $HOME/tap-gitops/clusters/$kube_context/cluster-config/values/
rm tap-sensitive-values.yaml

mkdir $HOME/tap-gitops/clusters/$kube_context/cluster-config/namespaces
rm $HOME/tap-gitops/clusters/$kube_context/cluster-config/namespaces/desired-namespaces.yaml
cat <<EOF | tee $HOME/tap-gitops/clusters/$kube_context/cluster-config/namespaces/desired-namespaces.yaml
#@data/values
---
namespaces:
#! The only required parameter is the name of the namespace. All additional values provided here 
#! for a namespace will be available under data.values for templating additional sources
- name: dev
- name: qa
EOF

rm $HOME/tap-gitops/clusters/$kube_context/cluster-config/namespaces/namespaces.yaml
cat <<EOF | tee $HOME/tap-gitops/clusters/$kube_context/cluster-config/namespaces/namespaces.yaml
#@ load("@ytt:data", "data")
#! This for loop will loop over the namespace list in desired-namespaces.yaml and will create those namespaces.
#! NOTE: if you have another tool like Tanzu Mission Control or some other process that is taking care of creating namespaces for you, 
#! and you don’t want namespace provisioner to create the namespaces, you can delete this file from your GitOps install repository.
#@ for ns in data.values.namespaces:
---
apiVersion: v1
kind: Namespace
metadata:
  name: #@ ns.name
#@ end
EOF

rm $HOME/tap-gitops/clusters/$kube_context/cluster-config/values/tap-non-sensitive-values.yaml
cat <<EOF | tee $HOME/tap-gitops/clusters/$kube_context/cluster-config/values/tap-non-sensitive-values.yaml
---
tap_install:
  values:
    profile: full
    ceip_policy_disclosed: true
    shared:
      ingress_domain: "$full_domain"
    supply_chain: basic
    ootb_supply_chain_basic:
      registry:
        server: $IMGPKG_REGISTRY_HOSTNAME_1
        repository: "supply-chain"
    contour:
      envoy:
        service:
          type: LoadBalancer
    ootb_templates:
      iaas_auth: true
    tap_gui:
      service_type: LoadBalancer
      app_config:
        catalog:
          locations:
            - type: url
              target: $git_catalog_repository
    metadata_store:
      ns_for_export_app_cert: "default"
      app_service_type: LoadBalancer
    scanning:
      metadataStore:
        url: "metadata-store.$full_domain"
    grype:
      namespace: "default"
      targetImagePullSecret: "registry-credentials"
    cnrs:
      domain_name: $full_domain
    namespace_provisioner:
      controller: false
      gitops_install:
        ref: origin/main
        subPath: clusters/tap-full/cluster-config/namespaces
        url: https://github.com/nycpivot/tap-gitops.git
    excluded_packages:
      - policy.apps.tanzu.vmware.com
EOF

rm registry-credentials.yaml
cat <<EOF | tee registry-credentials.yaml
tap_install:
 sensitive_values:
   shared:
     image_registry:
       project_path: "$IMGPKG_REGISTRY_HOSTNAME_1/build-service"
       username: "$IMGPKG_REGISTRY_USERNAME_1"
       password: "$IMGPKG_REGISTRY_PASSWORD_1"
EOF

#COPY CONTENTS OF FOLLOWING FILE...
cat registry-credentials.yaml

echo
read -p "Copy the above yaml and paste it into the following sops editor. Press Enter to continue..." fake_wait_prompt

#...AND PASTE IT HERE
./sops $HOME/tap-gitops/clusters/$kube_context/cluster-config/values/tap-sensitive-values.sops.yaml

export GIT_SSH_PRIVATE_KEY=$(cat $HOME/.ssh/id_ed25519)
export GIT_KNOWN_HOSTS=$(ssh-keyscan github.com)
export SOPS_AGE_KEY=$(cat $HOME/key.txt)
export TAP_PKGR_REPO=registry.tanzu.vmware.com/tanzu-application-platform/tap-packages

cd $HOME/tap-gitops/clusters/$kube_context

./tanzu-sync/scripts/configure.sh

git add cluster-config/ tanzu-sync/
git commit -m "Configure install of TAP 1.5.0"
git push


#INSTALL TAP
./tanzu-sync/scripts/deploy.sh


#SETUP DEVELOPER NAMESPACE CREDENTIALS
tanzu secret registry add registry-credentials \
  --server $IMGPKG_REGISTRY_HOSTNAME_1 \
  --username $IMGPKG_REGISTRY_USERNAME_1 \
  --password $IMGPKG_REGISTRY_PASSWORD_1 \
  --export-to-all-namespaces \
  --namespace tap-install \
  --yes

cd $HOME
