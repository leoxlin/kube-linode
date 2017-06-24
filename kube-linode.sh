#!/bin/bash
set -e
source ~/.kube-linode/utilities.sh

check_dep jq
check_dep openssl
check_dep curl
check_dep htpasswd
check_dep kubectl
check_dep ssh
check_dep base64

unset DATACENTER_ID
unset MASTER_PLAN
unset WORKER_PLAN
unset DOMAIN
unset EMAIL
unset MASTER_ID
unset API_KEY

stty -echo
tput civis

if [ -f ~/.kube-linode/settings.env ] ; then
    . ~/.kube-linode/settings.env
else
    touch ~/.kube-linode/settings.env
fi

read_api_key
read_datacenter
read_master_plan
read_worker_plan
read_domain
read_email
read_no_of_workers

#TODO: allow entering of username
USERNAME=$( whoami )

if [[ ! ( -f ~/.ssh/id_rsa && -f ~/.ssh/id_rsa.pub ) ]]; then
    echo_pending "Generating new SSH key"
    ssh-keygen -b 2048 -t rsa -f ~/.ssh/id_rsa -q -N ""
    echo_completed "Generating new SSH key"
fi

if [ -f ~/.kube-linode/auth ]  ; then : ; else
    echo "Key in your dashboard password (Required for https://kube.$DOMAIN, https://traefik.$DOMAIN)"
    htpasswd -c ~/.kube-linode/auth $USERNAME
fi

echo_pending "Updating install script"
update_script

echo_update "Retrieving master linode (if any)"
MASTER_ID=$( get_master_id )

if ! [[ $MASTER_ID =~ ^-?[0-9]+$ ]] 2>/dev/null; then
   echo_update "Retrieving list of workers"
   WORKER_IDS=$( list_worker_ids )
   for WORKER_ID in $WORKER_IDS; do
      echo_update "Deleting worker (since certs are now invalid)" $WORKER_ID
      linode_api linode.delete LinodeID=$WORKER_ID skipChecks=true >/dev/null
   done
   WORKER_ID=

   echo_update "Creating master linode"
   MASTER_ID=$( linode_api linode.create DatacenterID=$DATACENTER_ID PlanID=$MASTER_PLAN | jq ".DATA.LinodeID" )

   echo_update "Initializing labels" $MASTER_ID
   linode_api linode.update LinodeID=$MASTER_ID Label="master_${MASTER_ID}" lpm_displayGroup="$DOMAIN (Unprovisioned)" >/dev/null

   if [ -d ~/.kube-linode/certs ]; then
     echo_update "Removing existing certificates" $MASTER_ID
     rm -rf ~/.kube-linode/certs;
   fi
   echo_update "Creating master linode"
fi

echo_update "Getting IP" $MASTER_ID
MASTER_IP=$(get_ip $MASTER_ID); declare "IP_$MASTER_ID=$MASTER_IP"
echo_update "IP Address: $MASTER_IP" $MASTER_ID

echo_update "Retrieving provision status" $MASTER_ID
if [ "$( is_provisioned $MASTER_ID )" = false ] ; then
  echo_update "Master node not provisioned" $MASTER_ID
  update_dns $MASTER_ID
  install master $MASTER_ID

  echo_update "Setting defaults for kubectl"
  kubectl config set-cluster ${USERNAME}-cluster --server=https://${MASTER_IP}:6443 --certificate-authority=$HOME/.kube-linode/certs/ca.pem >/dev/null
  kubectl config set-credentials ${USERNAME} --certificate-authority=$HOME/.kube-linode/certs/ca.pem --client-key=$HOME/.kube-linode/certs/admin-key.pem --client-certificate=$HOME/.kube-linode/certs/admin.pem >/dev/null
  kubectl config set-context default-context --cluster=${USERNAME}-cluster --user=${USERNAME} >/dev/null
  kubectl config use-context default-context >/dev/null
fi
echo_completed "Master provisioned (IP: $MASTER_IP)" $MASTER_ID

echo_pending "Retrieving current number of workers" $MASTER_ID
CURRENT_NO_OF_WORKERS=$( echo "$( list_worker_ids | wc -l ) + 0" | bc )
echo_update "Current number of workers: $CURRENT_NO_OF_WORKERS" $MASTER_ID

NO_OF_NEW_WORKERS=$( echo "$NO_OF_WORKERS - $CURRENT_NO_OF_WORKERS" | bc )
echo_update "Number of new workers to add: $NO_OF_NEW_WORKERS" $MASTER_ID

if [[ $NO_OF_NEW_WORKERS -gt 0 ]]; then
    for WORKER in $( seq $NO_OF_NEW_WORKERS ); do
        echo_update "Creating worker linode" $MASTER_ID
        WORKER_ID=$( linode_api linode.create DatacenterID=$DATACENTER_ID PlanID=$WORKER_PLAN | jq ".DATA.LinodeID" )
        linode_api linode.update LinodeID=$WORKER_ID Label="worker_${WORKER_ID}" lpm_displayGroup="$DOMAIN (Unprovisioned)" >/dev/null
        echo_update "Created worker linode" $WORKER_ID
    done
fi

echo_update "Retrieving list of workers" $MASTER_ID
WORKER_IDS=$( list_worker_ids )
echo_completed "Retrieved list of workers" $MASTER_ID
tput cuu1
tput el

for WORKER_ID in $WORKER_IDS; do
   echo_pending "Getting IP" $WORKER_ID
   IP=$(get_ip $WORKER_ID); declare "IP_$WORKER_ID=$IP"
   echo_update "IP Address: $IP" $WORKER_ID
   echo_update "Retrieving provision status" $WORKER_ID
   if [ "$( is_provisioned $WORKER_ID )" = false ] ; then
     echo_update "Worker not provisioned" $WORKER_ID
     install worker $WORKER_ID
   fi
   echo_completed "Worker provisioned (IP: $IP)" $WORKER_ID
done

wait

tput cnorm
stty echo
