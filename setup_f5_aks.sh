#!/bin/bash

function print_usage() {
  CMD="$1"
  ERROR_MSG="$2"

  if [ "$ERROR_MSG" != "" ]; then
    echo -e "\nERROR: $ERROR_MSG"
  fi

  echo -e "\nUse this script to install Fusion 5 on AKS; optionally create a AKS cluster in the process"
  echo -e "\nUsage: $CMD [OPTIONS] ... where OPTIONS include:\n"
  echo -e "  -c          Name of the AKS cluster (required)\n"
  echo -e "  -p          Azure resource group (required)\n"
  echo -e "  -r          Helm release name for installing Fusion 5, defaults to 'f5'\n"
  echo -e "  -n          Kubernetes namespace to install Fusion 5 into, defaults to 'default'\n"
  echo -e "  -z          Azure location to launch the cluster in, defaults to 'eastus2'\n"
  echo -e "  -i          Instance type, defaults to 'Standard_B4ms'\n"
  echo -e "  -y          Azure Kubernetes Service node count, defaults to '4'\n"
  echo -e "  -t          Enable TLS for the ingress, requires a hostname to be specified with -h\n"
  echo -e "  -h          Hostname for the ingress to route requests to this Fusion cluster. If used with the -t parameter,\n              then the hostname must be a public DNS record that can be updated to point to the IP of the LoadBalancer\n"
  echo -e "  --version   Fusion Helm Chart version; defaults to the latest release from Lucidworks, such as 5.0.2-2\n"
  echo -e "  --values    Custom values file containing config overrides; defaults to <release>_<namespace>_fusion_values.yaml\n"
  echo -e "  --upgrade   Perform a Helm upgrade on an existing Fusion installation\n"
  echo -e "  --purge     Uninstall and purge all Fusion objects from the specified namespace and cluster.\n              Be careful! This operation cannot be undone.\n"
}

# prep for helm 3
helm=`which helm`

AKSIPT_CMD="$0"
AZURERG=
AZURE_LOCATION=eastus2
CLUSTER_NAME=
RELEASE=f5
NAMESPACE=default
MY_VALUES=${RELEASE}_${NAMESPACE}_fusion_values.yaml
UPGRADE=0
PURGE=0
INSTANCE_TYPE="Standard_B4ms"
CHART_VERSION="5.0.2-2"
ML_MODEL_STORE="fs"
CUSTOM_MY_VALUES=""
NODE_COUNT=4

if [ $# -gt 0 ]; then
  while true; do
    case "$1" in
        -c)
            if [[ -z "$2" || "${2:0:1}" == "-" ]]; then
              print_usage "$SCRIPT_CMD" "Missing value for the -c parameter!"
              exit 1
            fi
            CLUSTER_NAME="$2"
            shift 2
        ;;
        -n)
            if [[ -z "$2" || "${2:0:1}" == "-" ]]; then
              print_usage "$SCRIPT_CMD" "Missing value for the -n parameter!"
              exit 1
            fi
            NAMESPACE="$2"
            MY_VALUES="${RELEASE}_${NAMESPACE}_fusion_values.yaml"
            shift 2
        ;;
        -p)
            if [[ -z "$2" || "${2:0:1}" == "-" ]]; then
              print_usage "$SCRIPT_CMD" "Missing value for the -p parameter!"
              exit 1
            fi
            AZURERG="$2"
            shift 2
        ;;
        -r)
            if [[ -z "$2" || "${2:0:1}" == "-" ]]; then
              print_usage "$SCRIPT_CMD" "Missing value for the -r parameter!"
              exit 1
            fi
            RELEASE="$2"
            MY_VALUES="${RELEASE}_${NAMESPACE}_fusion_values.yaml"
            shift 2
        ;;
        -z)
            if [[ -z "$2" || "${2:0:1}" == "-" ]]; then
              print_usage "$SCRIPT_CMD" "Missing value for the -z parameter!"
              exit 1
            fi
            AZURE_LOCATION="$2"
            shift 2
        ;;
        -t)
            TLS_ENABLED=1
            shift 1
        ;;
        -h)
            if [[ -h "$2" || "${2:0:1}" == "-" ]]; then
              print_usage "$SCRIPT_CMD" "Missing value for the -h parameter!"
              exit 1
            fi
            INGRESS_HOSTNAME="$2"
            shift 2
        ;;
        -i)
            if [[ -z "$2" || "${2:0:1}" == "-" ]]; then
              print_usage "$SCRIPT_CMD" "Missing value for the -i parameter!"
              exit 1
            fi
            INSTANCE_TYPE="$2"
            shift 2
        ;;
        --version)
            if [[ -z "$2" || "${2:0:1}" == "-" ]]; then
              print_usage "$SCRIPT_CMD" "Missing value for the --version parameter!"
              exit 1
            fi
            CHART_VERSION="$2"
            shift 2
        ;;
        --values)
            if [[ -z "$2" || "${2:0:1}" == "-" ]]; then
              print_usage "$SCRIPT_CMD" "Missing value for the --values parameter!"
              exit 1
            fi
            CUSTOM_MY_VALUES="$2"
            shift 2
        ;;
        -y)
            if [[ -z "$2" || "${2:0:1}" == "-" ]]; then
              print_usage "$SCRIPT_CMD" "Missing value for the -y parameter!"
              exit 1
            fi
            NODE_COUNT="$2"
            shift 2
        ;;
        --upgrade)
            UPGRADE=1
            shift 1
        ;;
        --purge)
            PURGE=1
            shift 1
        ;;
        -help|-usage)
            print_usage "$SCRIPT_CMD"
            exit 0
        ;;
        --)
            shift
            break
        ;;
        *)
            if [ "$1" != "" ]; then
              print_usage "$SCRIPT_CMD" "Unrecognized or misplaced argument: $1!"
              exit 1
            else
              break # out-of-args, stop looping
            fi
        ;;
    esac
  done
fi

if [ "$CLUSTER_NAME" == "" ]; then
  print_usage "$SCRIPT_CMD" "Please provide the cluster name using: -c <cluster>"
  exit 1
fi

if [ "$AZURERG" == "" ]; then
  print_usage "$SCRIPT_CMD" "Please provide the Azure resource group name using: -p <azure resource group>"
  exit 1
fi

if [ -n "$CUSTOM_MY_VALUES" ]; then
  MY_VALUES=$CUSTOM_MY_VALUES
fi

if [ "${TLS_ENABLED}" == "1" ] && [ -z "${INGRESS_HOSTNAME}" ]; then
  print_usage "$SCRIPT_CMD" "if -t is specified -h must be specified and a domain that you can update to add an A record to point to the GCP Loadbalancer IP"
  exit 1
fi

# verify the user is logged in ...
who_am_i=$(az account show --query 'user.name'| sed -e 's/"//g')
if [ "$who_am_i" == "" ]; then
  echo -e "\nERROR: Azure user unknown, please use: 'az login' before proceeding with this script!"
  exit 1
fi

echo -e "\nLogged in as: $who_am_i\n"

hash kubectl
has_prereq=$?
if [ $has_prereq == 1 ]; then
  echo -e "\nERROR: Must install kubectl before proceeding with this script! For AKS, run 'az aks install-cli'"
  exit 1
fi

hash helm
has_prereq=$?
if [ $has_prereq == 1 ]; then
  echo -e "\nERROR: Must install helm before proceeding with this script! See: https://helm.sh/docs/using_helm/#quickstart"
  exit 1
fi

# check to see if the resource group exists
LISTOUT=`az group list --query "[?name=='${AZURERG}']"`
rglist_worked=$?
if [ $rglist_worked == 1 ]; then
  echo -e "\nERROR: listing for resource group failed. Check that az tool is properly installed."
  exit 1
fi

# Create the resource group if it doesn't exist
if [ "${LISTOUT}" == "[]" ]; then
  az group create -g $AZURERG -l $AZURE_LOCATION
  azgroupcreate=$?
  if [ $azgroupcreate == 1 ]; then
    echo -e "\nERROR: Unable to create resource group: ${AZURERG} in azure location: ${AZURE_LOCATION} check account permissions"
    exit 1
  fi
fi

if [ "$PURGE" == "1" ]; then
  az aks get-credentials -n ${CLUSTER_NAME} -g ${AZURERG}
  getcreds=$?
  if [ "$getcreds" != "0" ]; then
    echo -e "\nERROR: Can't find kubernetes cluster: ${CLUSTER_NAME} in Azure resource group ${AZURERG} to purge!"
    exit 1
  fi

  current=$(kubectl config current-context)
  read -p "Are you sure you want to purge the ${RELEASE} release from the ${NAMESPACE} in: $current? This operation cannot be undone! y/n " confirm
  if [ "$confirm" == "y" ]; then
    ${helm} del --purge ${RELEASE}
    kubectl delete deployments -l app.kubernetes.io/part-of=fusion --namespace "${NAMESPACE}" --grace-period=0 --force --timeout=5s
    kubectl delete job ${RELEASE}-api-gateway --namespace "${NAMESPACE}" --grace-period=0 --force --timeout=1s
    kubectl delete svc -l app.kubernetes.io/part-of=fusion --namespace "${NAMESPACE}" --grace-period=0 --force --timeout=2s
    kubectl delete pvc -l app.kubernetes.io/part-of=fusion --namespace "${NAMESPACE}" --grace-period=0 --force --timeout=5s
    kubectl delete pvc -l release=${RELEASE} --namespace "${NAMESPACE}" --grace-period=0 --force --timeout=5s
    kubectl delete pvc -l app.kubernetes.io/instance=${RELEASE} --namespace "${NAMESPACE}" --grace-period=0 --force --timeout=5s
  fi
  exit 0
fi

LISTOUT=`az aks list --query "[?name=='${CLUSTER_NAME}']"`
cluster_status=$?
if [ $cluster_status == 1 ]; then
  echo -e "\nERROR: error listing clusters"
  exit 1
fi

if [ "$LISTOUT" == "[]" ]; then
  echo -e "\nLaunching AKS cluster ${CLUSTER_NAME} in resource group ${AZURERG} in location ${AZURE_LOCATION} for deploying Lucidworks Fusion 5 ...\n"

  az aks create -g "${AZURERG}" -n "${CLUSTER_NAME}" --node-count ${NODE_COUNT} --node-vm-size ${INSTANCE_TYPE} 
  cluster_created=$?
  if [ "$cluster_created" != "0" ]; then
    echo -e "\nERROR: Status of AKS cluster ${CLUSTER_NAME} is suspect, check the Azure portal before proceeding!\n"
    exit 1
  fi
  echo -e "\nCluster '${CLUSTER_NAME}' deployed ... testing if it is healthy"

  # XXX: BDW: should be an easier way to do this
  az aks list --query "[].name" | grep ${CLUSTER_NAME} > /dev/null 2>&1
  cluster_status=$?
  if [ "$cluster_status" != "0" ]; then
    echo -e "\nERROR: Status of AKS cluster ${CLUSTER_NAME} is suspect, check the Azure portal before proceeding!\n"
    exit 1
  fi
else
  if [ "$UPGRADE" == "0" ]; then
    echo -e "\nAKS Cluster '${CLUSTER_NAME}' already exists, proceeding with Fusion 5 install ...\n"
  fi
fi

az aks get-credentials -n ${CLUSTER_NAME} -g ${AZURERG}
kubectl config current-context

function proxy_url() {
  export PROXY_HOST=$(kubectl --namespace "${NAMESPACE}" get service proxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  export PROXY_PORT=$(kubectl --namespace "${NAMESPACE}" get service proxy -o jsonpath='{.spec.ports[?(@.protocol=="TCP")].port}')
  export PROXY_URL=$PROXY_HOST:$PROXY_PORT
  echo -e "\n\nFusion 5 Gateway service exposed at: $PROXY_URL\n"
  echo -e "WARNING: This IP address is exposed to the WWW w/o SSL! This is done for demo purposes and ease of installation.\nYou are strongly encouraged to configure a K8s Ingress with TLS, see:\n   https://cloud.google.com/kubernetes-engine/docs/tutorials/http-balancer"
  echo -e "\nAfter configuring an Ingress, please change the 'proxy' service to be a ClusterIP instead of LoadBalancer\n"
}

function ingress_setup() {
  # XXX:BDW: UNTESTED
  export INGRESS_IP=$(kubectl --namespace "${NAMESPACE}" get ingress "${RELEASE}-api-gateway" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  # Patch yaml for now, until fix gets into helm charts
  kubectl patch --namespace "${NAMESPACE}" ingress "${RELEASE}-api-gateway" -p "{\"spec\":{\"rules\":[{\"host\": \"${INGRESS_HOSTNAME}\", \"http\":{\"paths\":[{\"backend\": {\"serviceName\": \"proxy\", \"servicePort\": 6764}, \"path\": \"/*\"}]}}]}}"
  echo -e "\n\nFusion 5 Gateway service exposed at: ${INGRESS_HOSTNAME}\n"
  echo -e "Please ensure that the public DNS record for ${INGRESS_HOSTNAME} is updated to point to ${INGRESS_IP}"
  echo -e "An SSL certificate will be automatically generated once the public DNS record has been updated, this may take up to an hour after DNS has updated to be issued"

}

kubectl rollout status deployment/${RELEASE}-query-pipeline -n ${NAMESPACE} --timeout=10s > /dev/null 2>&1
rollout_status=$?
if [ $rollout_status == 0 ]; then
  if [ "$UPGRADE" == "0" ]; then
    echo -e "\nLooks like Fusion is already running ..."
    proxy_url
    exit 0
  fi
fi

if [ "$UPGRADE" == "0" ]; then
  kubectl create clusterrolebinding cluster-admin-binding --clusterrole=cluster-admin --user=${who_am_i}
fi

# see if Tiller is deployed ...
kubectl rollout status deployment/tiller-deploy --timeout=10s -n kube-system > /dev/null 2>&1
rollout_status=$?
if [ $rollout_status != 0 ]; then
  echo -e "\nSetting up Helm Tiller ..."
  kubectl create serviceaccount --namespace kube-system tiller
  kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
  ${helm} init --service-account tiller --wait
  ${helm} version
fi

lw_helm_repo=lucidworks

echo -e "\nAdding the Lucidworks chart repo to helm repo list"
helm repo list | grep "https://charts.lucidworks.com"
if [ $? ]; then
  ${helm} repo add ${lw_helm_repo} https://charts.lucidworks.com

fi

if [ ! -f $MY_VALUES ] && [ "$UPGRADE" != "1" ]; then
  SOLR_REPLICAS=$(kubectl get nodes | grep "$CLUSTER_NAME" | wc -l)
  tee $MY_VALUES << END
cx-ui:
  replicaCount: 1
  resources:
    limits:
      cpu: "200m"
      memory: 64Mi
    requests:
      cpu: "100m"
      memory: 64Mi

cx-api:
  replicaCount: 1
  volumeClaimTemplates:
    storageSize: "5Gi"

kafka:
  replicaCount: 1
  resources: {}
  kafkaHeapOptions: "-Xmx512m"

sql-service:
  replicaCount: 0
  service:
    thrift:
      type: "ClusterIP"

solr:
  image:
    tag: 8.2.0
  updateStrategy:
    type: "RollingUpdate"
  javaMem: "-Xmx3g"
  volumeClaimTemplates:
    storageSize: "50Gi"
  replicaCount: ${SOLR_REPLICAS}
  resources: {}
  zookeeper:
    replicaCount: ${SOLR_REPLICAS}
    resources: {}
    env:
      ZK_HEAP_SIZE: 1G

ml-model-service:
  modelRepository:
    impl: ${ML_MODEL_STORE}
    gcs:
      bucketName: ${GCS_BUCKET}
      baseDirectoryName: dev

fusion-admin:
  readinessProbe:
    initialDelaySeconds: 180

fusion-indexing:
  readinessProbe:
    initialDelaySeconds: 180

query-pipeline:
  javaToolOptions: "-Dlogging.level.com.lucidworks.cloud=INFO"

END
  echo -e "\nCreated $MY_VALUES with default custom value overrides. Please save this file for customizing your Fusion installation and upgrading to a newer version.\n"
fi

${helm} repo update

ADDITIONAL_VALUES=""
if [ "${TLS_ENABLED}" == "1" ]; then
  cat <<EOF | kubectl -n "${NAMESPACE}" apply -f -
apiVersion: networking.gke.io/v1beta1
kind: ManagedCertificate
metadata:
  name: "${RELEASE}-managed-certificate"
spec:
  domains:
  - "${INGRESS_HOSTNAME}"
EOF

  TLS_VALUES="tls-values.yaml"
  ADDITIONAL_VALUES="${ADDITIONAL_VALUES} --values tls-values.yaml"
  tee "${TLS_VALUES}" << END
api-gateway:
  service:
    type: "NodePort"
  ingress:
    enabled: true
    host: "${INGRESS_HOSTNAME}"
    tls:
      enabled: true
    annotations:
      "networking.gke.io/managed-certificates": "${RELEASE}-managed-certificate"
      "kubernetes.io/ingress.class": "gce"

END
fi

if [ "$UPGRADE" == "1" ]; then

  VALUES_ARG="--values ${MY_VALUES}"
  if [ ! -f "${MY_VALUES}" ]; then
    echo -e "\nWARNING: Custom values file ${MY_VALUES} not found!\nYou need to provide the same custom values you provided when creating the cluster in order to upgrade.\n"
    exit 1
  fi

  if [ "${DRY_RUN}" == "" ]; then
    echo -e "\nUpgrading the Fusion 5 release ${RELEASE} in namespace ${NAMESPACE} to version ${CHART_VERSION} using ${VALUES_ARG} ${ADDITIONAL_VALUES}"
  else
    echo -e "\nSimulating an update of the Fusion ${RELEASE} installation into the ${NAMESPACE} namespace using ${VALUES_ARG} ${ADDITIONAL_VALUES}"
  fi

  ${helm} upgrade ${RELEASE} "${lw_helm_repo}/fusion" --timeout 180 --namespace "${NAMESPACE}" ${VALUES_ARG} ${ADDITIONAL_VALUES} --version ${CHART_VERSION}
  upgrade_status=$?
  if [ "${TLS_ENABLED}" == "1" ]; then
    ingress_setup
  else
    proxy_url
  fi
  exit $upgrade_status
fi

echo -e "\nInstalling Fusion 5.0 Helm chart ${CHART_VERSION} into namespace ${NAMESPACE} with release tag: ${RELEASE} using custom values from ${MY_VALUES}"
${helm} install --timeout 240 --namespace "${NAMESPACE}" -n "${RELEASE}" --values "${MY_VALUES}" ${ADDITIONAL_VALUES} ${lw_helm_repo}/fusion --version ${CHART_VERSION}
kubectl rollout status deployment/${RELEASE}-api-gateway --timeout=600s --namespace "${NAMESPACE}"
kubectl rollout status deployment/${RELEASE}-fusion-admin --timeout=600s --namespace "${NAMESPACE}"

if [ "${TLS_ENABLED}" == "1" ]; then
  ingress_setup
else
  proxy_url
fi