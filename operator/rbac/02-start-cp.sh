#!/bin/bash

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

# read configuration files
#
if [ -r ${DIR}/test.properties ]
then
    . ${DIR}/test.properties
else
    logerror "Cannot read configuration file ${DIR}/test.properties"
    exit 1
fi

verify_installed "kubectl"
verify_installed "helm"
verify_installed "aws"
verify_installed "eksctl"
verify_installed "cfssl"

log "Generating certs"
# https://github.com/confluentinc/cp-operator-deployment/tree/master/test/helm/scenarios/manual/certs/generate-certs

# CA
cfssl gencert -initca ${DIR}/certs/ca-csr.json | cfssljson -bare ${DIR}/certs/ca -

# Server Certificates
cat ${DIR}/certs/server-aws-template.json | sed 's/__DOMAIN__/'"$domain"'/g' > ${DIR}/certs/server-aws.json
cfssl gencert -ca=${DIR}/certs/ca.pem -ca-key=${DIR}/certs/ca-key.pem -config=${DIR}/certs/ca-config.json -profile=server ${DIR}/certs/server-aws.json | cfssljson -bare ${DIR}/certs/server-aws

# components
./generate_certs.sh "operator" "$domain"

# private repo https://github.com/confluentinc/cp-operator-deployment/tree/master/test/helm/scenarios/manual/rbac

########
# MAKE SURE TO BE IDEMPOTENT
########
set +e
kubectl delete namespace operator
# delete namespaces
# https://github.com/kubernetes/kubernetes/issues/77086#issuecomment-486840718
# kubectl delete namespace operator --wait=false
# kubectl get ns operator -o json | jq '.spec.finalizers=[]' > ns-without-finalizers.json
# curl -X PUT http://localhost:8001/api/v1/namespaces/operator/finalize -H "Content-Type: application/json" --data-binary @ns-without-finalizers.json
set -e

VALUES_FILE=${DIR}/providers/aws.yaml

log "Generate VALUES_FILE Yaml File"
cat ${DIR}/providers/aws-template.yaml | sed 's/__DOMAIN__/'"$domain"'/g' | sed 's/__USER__/'"$USER"'/g' | sed 's/eks_region/'"$eks_region"'/g' > ${VALUES_FILE}

log "Download Confluent Operator confluent-operator-1.6.1-for-confluent-platform-6.0.0.tar.gz in ${DIR}/confluent-operator"
rm -rf ${DIR}/confluent-operator
mkdir ${DIR}/confluent-operator
cd ${DIR}/confluent-operator
wget https://platform-ops-bin.s3-us-west-1.amazonaws.com/operator/confluent-operator-1.6.1-for-confluent-platform-6.0.0.tar.gz
tar xvfz confluent-operator-1.6.1-for-confluent-platform-6.0.0.tar.gz
cd -

log "Extend Kubernetes with first class CP primitives"
kubectl apply --filename ${DIR}/confluent-operator/resources/crds/

log "Create the Kubernetes namespaces to install Operator and cluster"
kubectl create namespace operator

log "Installing operator"
helm upgrade --install \
  operator \
  ${DIR}/confluent-operator/helm/confluent-operator/ \
  --values $VALUES_FILE \
  --namespace operator \
  --set operator.enabled=true \
  --wait

kubectl config set-context --current --namespace=operator

log "Install ldap charts for testing"
helm upgrade --install -f ${DIR}/openldap/ldaps-rbac.yaml test-ldap ${DIR}/openldap \
  --set-file tls.fullchain=${PWD}/certs/component-certs/kafka/kafka.pem  \
  --set-file tls.privkey=${PWD}/certs/component-certs/kafka/kafka-key.pem \
  --set-file tls.cacerts=${PWD}/certs/ca.pem \
  --namespace operator

log "Note: All required username/password are already part of openldap/values.yaml"

# https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/aws.md

log "Create IAM Policy, if required"
set +e
policy_arn=$(aws iam list-policies --query 'Policies[?PolicyName==`playground-operator-rbac-policy`].Arn' --output text)
aws iam delete-policy --policy-arn "${policy_arn}"
aws iam create-policy --policy-name "playground-operator-rbac-policy" --policy-document file://iam-policy-allow-externl-dns-updates.json --output text
set -e

policy_arn=$(aws iam list-policies --query 'Policies[?PolicyName==`playground-operator-rbac-policy`].Arn' --output text)

eksctl utils associate-iam-oidc-provider --region=${eks_region} --cluster=${eks_cluster_name} --approve
# https://docs.aws.amazon.com/eks/latest/userguide/create-service-account-iam-policy-and-role.html

set +e
log "Delete IAM role for playground-operator-rbac-sa service account, if required"
eksctl delete iamserviceaccount --cluster ${eks_cluster_name} --name playground-operator-rbac-sa
set -e
log "Create IAM role for playground-operator-rbac-sa service account"
eksctl create iamserviceaccount \
    --name playground-operator-rbac-sa \
    --namespace operator \
    --cluster ${eks_cluster_name} \
    --attach-policy-arn ${policy_arn} \
    --approve \
    --override-existing-serviceaccounts

iam_service_role=$(eksctl get iamserviceaccount --cluster "${eks_cluster_name}" --name "playground-operator-rbac-sa" --namespace operator -ojson | jq -r '.iam.serviceAccounts[].status.roleARN' | tail -1)

set +e
hosted_zone_id=$(aws route53 list-hosted-zones-by-name --output json --dns-name "${domain}." | jq -r '.HostedZones[0].Id')
log "Delete hosted zone ${hosted_zone_id}, if required"
aws route53 delete-hosted-zone --id ${hosted_zone_id}
set -e
log "Create a DNS zone which will contain the managed DNS records"
aws route53 create-hosted-zone --name "${domain}." --caller-reference "external-dns-test-$(date +%s)"
hosted_zone_id=$(aws route53 list-hosted-zones-by-name --output json --dns-name "${domain}." | jq -r '.HostedZones[0].Id')
log "Make a note of the nameservers that were assigned to your new zone ${hosted_zone_id}"
aws route53 list-resource-record-sets --output json --hosted-zone-id ${hosted_zone_id} --query "ResourceRecordSets[?Type == 'NS']" | jq -r '.[0].ResourceRecords[].Value'
set -e

set +e
kubectl delete clusterrole external-dns
kubectl delete clusterrolebinding external-dns
set -e
log "Install External DNS"
helm upgrade --install external-dns \
  --set provider=aws \
  --set aws.zoneType=public \
  --set aws.region=${eks_region} \
  --set policy=sync \
  --set registry=txt \
  --set interval=1m \
  --set txtOwnerId=${hosted_zone_id} \
  --set log-level=debug \
  --namespace operator \
  --set domainFilters[0]="${domain}." \
  stable/external-dns

sleep 60

log "Deploy Zookeeper Cluster"
helm upgrade --install zookeeper -f $VALUES_FILE ${DIR}/confluent-operator/helm/confluent-operator/ --namespace operator --set zookeeper.enabled=true --wait

log "Deploy Kafka Cluster"
helm upgrade --install kafka -f $VALUES_FILE ${DIR}/confluent-operator/helm/confluent-operator/ \
    --namespace operator \
    --set kafka.enabled=true \
    --set-file kafka.tls.fullchain=${PWD}/certs/component-certs/kafka/kafka.pem  \
    --set-file kafka.tls.privkey=${PWD}/certs/component-certs/kafka/kafka-key.pem \
    --set-file kafka.tls.cacerts=${PWD}/certs/ca.pem \
    --wait

log "Generate keystore and truststore first (client)"
${DIR}/scripts/createKeystore.sh ${DIR}/certs/component-certs/kafka/kafka.pem ${DIR}/certs/component-certs/kafka/kafka-key.pem
${DIR}/scripts/createTruststore.sh ${DIR}/certs/ca.pem

log "Generate kafka.properties"
cat ${DIR}/kafka.properties.tmpl | sed 's/__DOMAIN__/'"$domain"'/g' | sed 's/__USER__/'"$USER"'/g' > ${DIR}/kafka.properties

log "Waiting up to 1800 seconds for all pods in namespace operator to start"
wait-until-pods-ready "1800" "10" "operator"

log "Kafka Sanity Testing"
kafka-broker-api-versions --command-config ${DIR}/kafka.properties --bootstrap-server "$USER.$domain:9092"

# kubectl exec -it connectors-0 -- bash


# set +e
# # Verify Kafka Connect has started within MAX_WAIT seconds
# MAX_WAIT=480
# CUR_WAIT=0
# log "Waiting up to $MAX_WAIT seconds for Kafka Connect connectors-0 to start"
# kubectl logs connectors-0 > /tmp/out.txt 2>&1
# while [[ ! $(cat /tmp/out.txt) =~ "Finished starting connectors and tasks" ]]; do
#   sleep 10
#   kubectl logs connectors-0 > /tmp/out.txt 2>&1
#   CUR_WAIT=$(( CUR_WAIT+10 ))
#   if [[ "$CUR_WAIT" -gt "$MAX_WAIT" ]]; then
#     echo -e "\nERROR: The logs in connectors-0 container do not show 'Finished starting connectors and tasks' after $MAX_WAIT seconds. Please troubleshoot'.\n"
#     tail -300 /tmp/out.txt
#     exit 1
#   fi
# done
# log "Connect connectors-0 has started!"
# set -e

