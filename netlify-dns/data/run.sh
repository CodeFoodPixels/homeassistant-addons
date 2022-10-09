#!/usr/bin/with-contenv bashio

CERT_DIR=/data/letsencrypt
WORK_DIR=/data/workdir
NETLIFY_API="https://api.netlify.com/api/v1"

LE_UPDATE=0

TOKEN=$(bashio::config 'token')
DOMAIN=$(bashio::config 'domain')
SUBDOMAIN=$(bashio::config 'subdomain')
WAIT_TIME=$(bashio::config 'seconds')
ALGO=$(bashio::config 'lets_encrypt.algo')
IPV4_PATTERN='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'

function getIP() {
  EXTERNAL_IP=`dig -4 +short myip.opendns.com @resolver1.opendns.com`

  if [[ ! $EXTERNAL_IP =~ $IPV4_PATTERN ]]; then
    bashio::log.debug "IP Response: ${EXTERNAL_IP}"
    bashio::exit.nok "There was a problem resolving the external IP"
  fi
}

function updateNetlify() {
  local DNS_ZONES_RESPONSE=$(curl -s -w "%{http_code}" "$NETLIFY_API/dns_zones?TOKEN=$TOKEN" --header "Content-Type:application/json")
  local DNS_ZONES_RESPONSE_CODE=${DNS_ZONES_RESPONSE: -3}
  local DNS_ZONES_CONTENT=${DNS_ZONES_RESPONSE%???}
  if [[ $DNS_ZONES_RESPONSE_CODE != 200 ]]; then 
    bashio::log.debug "DNS zones response code: ${DNS_ZONES_RESPONSE_CODE}"
    bashio::log.debug "DNS zones response body: ${DNS_ZONES_CONTENT}"
    bashio::exit.nok "There was a problem retrieving the DNS zones from Netlify"
  fi

  local ZONE_ID=`echo $DNS_ZONES_CONTENT | jq ".[]  | select(.name == \"$DOMAIN\") | .id" --raw-output`

  local DNS_RECORDS_RESPONSE=$(curl -s -w "%{http_code}" "$NETLIFY_API/dns_zones/$ZONE_ID/dns_records?TOKEN=$TOKEN" --header "Content-Type:application/json")
  local DNS_RECORDS_RESPONSE_CODE=${DNS_RECORDS_RESPONSE: -3}
  local DNS_RECORDS_CONTENT=${DNS_RECORDS_RESPONSE%???}
  if [[ $DNS_RECORDS_RESPONSE_CODE != 200 ]]; then
    bashio::log.debug "DNS records response code: ${DNS_RECORDS_RESPONSE_CODE}"
    bashio::log.debug "DNS records response body: ${DNS_RECORDS_CONTENT}"
    bashio::exit.nok "There was a problem retrieving the DNS records from Netlify for zone \"$ZONE_ID\""
  fi

  local HOSTNAME="$SUBDOMAIN.$DOMAIN"
  local RECORD=`echo $DNS_RECORDS_CONTENT | jq ".[]  | select(.hostname == \"$HOSTNAME\" and .type == "A")" --raw-output`
  local RECORD_VALUE=`echo $RECORD | jq ".value" --raw-output`

  if [[ "$RECORD_VALUE" != "$EXTERNAL_IP" ]]; then

    bashio::log.debug "Current external IP is $EXTERNAL_IP, current $HOSTNAME value is $RECORD_VALUE"

    if [[ $RECORD_VALUE =~ $IP_PATTERN ]]; then
      bashio::log.debug "Deleting current entry for $HOSTNAME"
      local RECORD_ID=`echo $RECORD | jq ".id" --raw-output`
      local DELETE_RESPONSE_CODE=`curl -X DELETE -s -w "%{http_code}" "$NETLIFY_API/dns_zones/$ZONE_ID/dns_records/$RECORD_ID?TOKEN=$TOKEN" --header "Content-Type:application/json"`

      if [[ $DELETE_RESPONSE_CODE != 204 ]]; then
        bashio::log.debug "Deletion response code: ${DELETE_RESPONSE_CODE}"
        bashio::exit.nok "There was a problem deleting the existing $HOSTNAME entry"
      fi
    fi

    bashio::log.debug "Creating new entry for $HOSTNAME with value $EXTERNAL_IP"
    local CREATE_BODY=`jq -n --arg hostname "$HOSTNAME" --arg externalIp "$EXTERNAL_IP" --arg ttl $WAIT_TIME
    '
    {
        "type": "A",
        "hostname": $hostname,
        "value": $externalIp,
        "ttl": $ttl|tonumber
    }'`

    local CREATE_RESPONSE=`curl -s -w "%{http_code}" --data "$CREATE_BODY" "$NETLIFY_API/dns_zones/$ZONE_ID/dns_records?TOKEN=$TOKEN" --header "Content-Type:application/json"`
    local CREATE_RESPONSE_RESPONSE_CODE=${CREATE_RESPONSE: -3}
    local CREATE_RESPONSE_CONTENT=${CREATE_RESPONSE%???}
    if [[ $CREATE_RESPONSE_CODE != 201 ]]; then

      bashio::log.debug "Create response code: ${CREATE_RESPONSE_CODE}"
      bashio::log.debug "Create response body: ${CREATE_RESPONSE_CONTENT}"
      bashio::exit.nok "There was a problem creating the new entry for $HOSTNAME on Netlift"
    fi
  fi
}

function renewLetsEncrypt() {
    HOSTNAME="$SUBDOMAIN.$DOMAIN"

    dehydrated --cron --algo "${ALGO}" --hook ./hooks.sh --challenge dns-01 --domain "${HOSTNAME}" --out "${CERT_DIR}" --config "${WORK_DIR}/config" || true
    LE_UPDATE="$(date +%s)"
}

if [[ bashio::config.has_value "ip" ]]; then
  EXTERNAL_IP=$(bashio::config 'ip');
  if [[ ! $EXTERNAL_IP =~ $IPV4_PATTERN ]]; then
    bashio::log.debug "${EXTERNAL_IP}"
    getIP
  fi
else
  getIP
fi

if bashio::config.true 'lets_encrypt.accept_terms'; then
    mkdir -p "${CERT_DIR}"
    mkdir -p "${WORK_DIR}"

    if [ -e "${WORK_DIR}/lock" ]; then
        rm -f "${WORK_DIR}/lock"
        bashio::log.warning "Reset dehydrated lock file"
    fi

    if [ ! -d "${CERT_DIR}/live" ]; then
        touch "${WORK_DIR}/config"
        dehydrated --register --accept-terms --config "${WORK_DIR}/config"
    fi
fi

while true; do
  updateNetlify

  now="$(date +%s)"
  if bashio::config.true 'lets_encrypt.accept_terms' && [ $((now - LE_UPDATE)) -ge 43200 ]; then
      renewLetsEncrypt
  fi

  sleep "${WAIT_TIME}"
done