#!/bin/bash
# shellcheck disable=SC2034
set -e

CONFIG_PATH=/data/options.json

NETLIFY_API="https://api.netlify.com/api/v1"

SYS_TOKEN=$(jq --raw-output '.token' $CONFIG_PATH)
SYS_DOMAIN=$(jq --raw-output '.domain' $CONFIG_PATH)
SYS_SUBDOMAIN=$(jq --raw-output '.subdomain' $CONFIG_PATH)
SYS_CERTFILE=$(jq --raw-output '.lets_encrypt.certfile' $CONFIG_PATH)
SYS_KEYFILE=$(jq --raw-output '.lets_encrypt.keyfile' $CONFIG_PATH)

# https://github.com/lukas2511/dehydrated/blob/master/docs/examples/hook.sh

function updateNetlify() {
  local TXT_VALUE="${1}"
  local DNS_ZONES_RESPONSE=$(curl -s -w "%{http_code}" "$NETLIFY_API/dns_zones?TOKEN=$SYS_TOKEN" --header "Content-Type:application/json")
  local DNS_ZONES_RESPONSE_CODE=${DNS_ZONES_RESPONSE: -3}
  local DNS_ZONES_CONTENT=${DNS_ZONES_RESPONSE%???}
  if [[ $DNS_ZONES_RESPONSE_CODE != 200 ]]; then 
    echo "DNS zones response code: ${DNS_ZONES_RESPONSE_CODE}"
    echo "DNS zones response body: ${DNS_ZONES_CONTENT}"
    echo "There was a problem retrieving the DNS zones from Netlify"
    exit
  fi

  local ZONE_ID=`echo $DNS_ZONES_CONTENT | jq ".[]  | select(.name == \"$SYS_DOMAIN\") | .id" --raw-output`

  local DNS_RECORDS_RESPONSE=$(curl -s -w "%{http_code}" "$NETLIFY_API/dns_zones/$ZONE_ID/dns_records?TOKEN=$SYS_TOKEN" --header "Content-Type:application/json")
  local DNS_RECORDS_RESPONSE_CODE=${DNS_RECORDS_RESPONSE: -3}
  local DNS_RECORDS_CONTENT=${DNS_RECORDS_RESPONSE%???}
  if [[ $DNS_RECORDS_RESPONSE_CODE != 200 ]]; then
    echo "DNS records response code: ${DNS_RECORDS_RESPONSE_CODE}"
    echo "DNS records response body: ${DNS_RECORDS_CONTENT}"
    echo "There was a problem retrieving the DNS records from Netlify for zone \"$ZONE_ID\""
    exit
  fi

  local HOSTNAME="$SYS_SUBDOMAIN.$SYS_DOMAIN"
  local RECORD=`echo $DNS_RECORDS_CONTENT | jq ".[]  | select(.hostname == \"$HOSTNAME\" and .type == "TXT")" --raw-output`
  local RECORD_VALUE=`echo $RECORD | jq ".value" --raw-output`

  if [[ "$RECORD_VALUE" != "$TXT_VALUE" ]]; then
    if [[ ! -z "$RECORD_VALUE" ]]; then
      echo "Deleting current entry for $HOSTNAME"
      local RECORD_ID=`echo $RECORD | jq ".id" --raw-output`
      local DELETE_RESPONSE_CODE=`curl -X DELETE -s -w "%{http_code}" "$NETLIFY_API/dns_zones/$ZONE_ID/dns_records/$RECORD_ID?TOKEN=$SYS_TOKEN" --header "Content-Type:application/json"`

      if [[ $DELETE_RESPONSE_CODE != 204 ]]; then
        echo "Deletion response code: ${DELETE_RESPONSE_CODE}"
        echo "There was a problem deleting the existing $HOSTNAME entry"
        exit
      fi
    fi

    if [[ ! -z "$TXT_VALUE" ]]; then
      local CREATE_BODY=`jq -n --arg hostname "_acme-challenge.$HOSTNAME" --arg txtValue "$TXT_VALUE"
      '
      {
          "type": "TXT",
          "hostname": $hostname,
          "value": $txtValue
      }'`

      local CREATE_RESPONSE=`curl -s -w "%{http_code}" --data "$CREATE_BODY" "$NETLIFY_API/dns_zones/$ZONE_ID/dns_records?TOKEN=$SYS_TOKEN" --header "Content-Type:application/json"`
      local CREATE_RESPONSE_RESPONSE_CODE=${CREATE_RESPONSE: -3}
      local CREATE_RESPONSE_CONTENT=${CREATE_RESPONSE%???}
      if [[ $CREATE_RESPONSE_CODE != 201 ]]; then

        echo "Create response code: ${CREATE_RESPONSE_CODE}"
        echo "Create response body: ${CREATE_RESPONSE_CONTENT}"
        echo "There was a problem creating the new entry for $HOSTNAME on Netlift"
        exit
      fi
    fi
  fi
}

deploy_challenge() {
    local TOKEN_VALUE="${3}"
    
    updateNetlify $TOKEN_VALUE
}

clean_challenge() {
   updateNetlify
}

deploy_cert() {
    local DOMAIN="${1}" KEYFILE="${2}" CERTFILE="${3}" FULLCHAINFILE="${4}" CHAINFILE="${5}" TIMESTAMP="${6}"

    # This hook is called once for each certificate that has been
    # produced. Here you might, for instance, copy your new certificates
    # to service-specific locations and reload the service.
    #
    # Parameters:
    # - DOMAIN
    #   The primary domain name, i.e. the certificate common
    #   name (CN).
    # - KEYFILE
    #   The path of the file containing the private key.
    # - CERTFILE
    #   The path of the file containing the signed certificate.
    # - FULLCHAINFILE
    #   The path of the file containing the full certificate chain.
    # - CHAINFILE
    #   The path of the file containing the intermediate certificate(s).
    # - TIMESTAMP
    #   Timestamp when the specified certificate was created.

     cp -f "$FULLCHAINFILE" "/ssl/$SYS_CERTFILE"
     cp -f "$KEYFILE" "/ssl/$SYS_KEYFILE"
}


HANDLER="$1"; shift
if [[ "${HANDLER}" =~ ^(deploy_challenge|clean_challenge|deploy_cert)$ ]]; then
  "$HANDLER" "$@"
fi
