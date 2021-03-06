#!/bin/bash

# Create a cluster and a resource group for it, if it does not exist
# The default configuration of this file assumes that:
# 1) You already have a cluster and a resource group
# 2) You are currently working in that specific context
# 3) You already have Azure CLI and Kubectl installed.
# 
# If that's not the case, uncomment the next section. This
# will create a new resource group, a new cluster, switch
# to that cluster automatically, and proceed with the installation.
# See this link for a thorough walkthrough 
# https://docs.microsoft.com/en-us/azure/aks/kubernetes-walkthrough
AZURE_PRODUCTION_CLUSTER_NAME=stihl-production-cluster;
AZURE_RG_FOR_CLUSTER=stihl-production-rg;

# az group create --name "$AZURE_RG_FOR_CLUSTER" --location eastus
# az aks create \
# --resource-group "$AZURE_RG_FOR_CLUSTER" \
# --name "$AZURE_PRODUCTION_CLUSTER_NAME" 
# --node-count 1 \
# --enable-addons monitoring \
# --generate-ssh-keys;
# 
# 
# Set the current context to the new cluster
# az aks get-credentials --resource-group "$AZURE_RG_FOR_CLUSTER" --name "$AZURE_PRODUCTION_CLUSTER_NAME"
# NOTE: If you're using Azure Container Registry to manage images,
# you have to attach it to each cluster (prod, dev) that uses those images.
# az aks update -n stihl-development-cluster \
# -g stihl-production-rg \
# --attach-acr stihlproductionacr

# Define where Velero backups will be stored. If a separate cluster is
# desired, change the value and uncomment the next az command
AZURE_BACKUP_RESOURCE_GROUP=stihl-production-rg;

# uncomment if the rg needs to be created
# az group create -n $AZURE_BACKUP_RESOURCE_GROUP --location eastus;

# The name of the storage account has to be unique. Use UUIDGen to 
# create a unique name and then create the Azure storage account
AZURE_STORAGE_ACCOUNT_ID="velero$(uuidgen | cut -d '-' -f5 | tr '[A-Z]' '[a-z]')";
az storage account create \
    --name $AZURE_STORAGE_ACCOUNT_ID \
    --resource-group $AZURE_BACKUP_RESOURCE_GROUP \
    --sku Standard_LRS \
    --encryption-services blob \
    --https-only true \
    --kind BlobStorage \
    --access-tier Hot; 

# Create the container itself
BLOB_CONTAINER=stihl-velero
az storage container create \
--name $BLOB_CONTAINER \
--public-access off \
--account-name $AZURE_STORAGE_ACCOUNT_ID;


# When you first create an AKS cluster, you're asked to define
# the resource group that will contain it. THIS IS NOT THAT!
# When you run the AKS command to create the cluster it will
# automatically create a separate cluster whose name is also
# comprised of its region and other information. Run this command
# in this format to get the correct resource group.
#
# az aks show --query nodeResourceGroup \
# --name <NAME-OF-TARGET-CLUSTER-YOU-MANUALLY-CREATED> \
# --resource-group <NAME-OF-RESOURCE-GROUP-YOU-MANUALLY-CREATED-FOR-CLUSTER> \
# --output tsv
#
# The name returned will be in a format like MC_RG_Name_Cluster_name_Region
# See this issue https://github.com/Azure/AKS/issues/3
AZURE_RESOURCE_GROUP=$(az aks show --query nodeResourceGroup --name "$AZURE_PRODUCTION_CLUSTER_NAME" --resource-group "$AZURE_RG_FOR_CLUSTER" --output tsv);

# Create the Service principal Velero needs to interact with the storage container

# Get your currently-in-use Subscription ID
AZURE_SUBSCRIPTION_ID=$(az account list --query '[?isDefault].id' -o tsv);

# Get your Tenant ID
AZURE_TENANT_ID=$(az account list --query '[?isDefault].tenantId' -o tsv);

# Create the service principal. Let the password be autogenerated and assigned to the variable.
# To Ensure that the value for --name does not conflict with other service principals 
# and app registrations, we're simply reusing the UUID Generated name from earlier.
AZURE_CLIENT_SECRET=$(az ad sp create-for-rbac --name "$AZURE_STORAGE_ACCOUNT_ID" --role "Contributor" --query 'password' -o tsv);

# After creating the service principal get the CLIENT_ID
AZURE_CLIENT_ID=$(az ad sp list --display-name "$AZURE_STORAGE_ACCOUNT_ID" --query '[0].appId' -o tsv);

# Create a secrets file that will be used with `velero install`
# NOTE: CONTAINS SENSITIVE DATA - DO NOT LET THIS GET COMMITTED!
# Add credentials-velero to .gitignore, .dockerignore, etc. Better
# yet, create a secrets folder, store all secrets there, and ignore
# the folder.
cat << EOF  > ./credentials-velero
AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
AZURE_TENANT_ID=${AZURE_TENANT_ID}
AZURE_CLIENT_ID=${AZURE_CLIENT_ID}
AZURE_CLIENT_SECRET=${AZURE_CLIENT_SECRET}
AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP}
AZURE_CLOUD_NAME=AzurePublicCloud
EOF

# Using the file, install Velero into AZURE_PRODUCTION_CLUSTER_NAME
# Download and install Velero if you haven't done so already
# https://velero.io/docs/install-overview/
velero install \
    --provider azure \
    --plugins velero/velero-plugin-for-microsoft-azure:v1.3.0 \
    --bucket $BLOB_CONTAINER \
    --secret-file ./credentials-velero \
    --backup-location-config resourceGroup="$AZURE_BACKUP_RESOURCE_GROUP",storageAccount="$AZURE_STORAGE_ACCOUNT_ID" \
    --snapshot-location-config apiTimeout=3m;


    # references:
    # https://documentation.suse.com/suse-caasp/4.2/html/caasp-admin/id-backup-and-restore-with-velero.html
    # https://github.com/vmware-tanzu/velero-plugin-for-microsoft-azure
    # https://docs.microsoft.com/en-us/azure-stack/aks-hci/backup-workload-cluster
    # https://youtu.be/8skHGzUBZ-Q?t=1277
    # https://tanzu.vmware.com/developer/guides/what-is-velero/