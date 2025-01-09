#!/usr/bin/bash
##  Author: Maulik Vaidya
##  Email: maulik.vaidya@gmail.com
##  Usage: 
##    -f: {mandatory} default vaules
##      true: use default values (domain=makkan.homes together with its sub-domains)
##      false: supply other values
##    -d: {optional} domain
##    -s: {optional} array of sub-domains. For operation on root domain use " "
##    -i: {optional} array of ids
##
##  Pre-reqs:
##    - Porkbun provider account
##    - API token for the account
##    - API use set to enabled on the domains of interest
##
##  Intention: 
##    Dynamic DNS capabilties when using [Porkbun APIs] (https://porkbun.com/api/json/v3/documentation)
##
##    I use it together with a cron job (per below) to:
##      - Obtain externally visible IP address of my firewall
##      - For each domain's {sub-domain, id} combination, retrieve currently provisioned A record via REST API
##        - Skip to next entry if A record IP matches externally visible IP
##        - Else update A record via REST API
##    
##    Linux cron job sample entry
##      0 */15 * * * <user> <path>/ddns.sh -f true | sudo tee -a /var/log/cron.log > /dev/null
##      0 */15 * * * <user> <path>/ddns.sh -f false -d "domain1" -s "sub1" -s "sub2" -i "id1" | sudo tee -a /var/log/cron.log > /dev/null


set -E

function log() {
    local      msg_args=("${@}")
    local      timestamp="$(date +'%Y-%m-%d %T')"
    declare -u log_level="${msg_args[0]}"
    local      message="${msg_args[@]:1}"

    echo -e "${timestamp} | ${log_level} | ${message}"
}

function fatal_log() {
    declare  -a  return_codes=("${PIPESTATUS[@]}")
    local    -r  array_length="$((${#return_codes[@]}-1))"
    local    -r  return_code="${return_codes[array_length]}"

    log fatal "Script **${0}** failed **${CURR_EXEC}** ...\n<-- with return code **${return_code}**\n <-- on **${BASH_LINENO[0]}** : **${BASH_COMMAND}**"

    rm -f "$tmp_file"

    exit "$return_code"
}
trap fatal_log ERR

# Appends logs to a file
log_file="/var/log/ddns.log"
exec > >(tee -a "${log_file}") 2>&1

declare -a subdomain domain_id

## --
## Variables 
## -
ttl="600"
rec_type="A"
base_url="https://api.porkbun.com/api/json/v3/dns"
api="<your_api_token>"
secret="<your_secret_token_for_api>"
domain="<domain>" # used in GET query as :domain
# used in POST query as payload :name
# leave blank to create record on the root domain
# if updating sub-domain, use just the subdomain part without fqdn e.g. `jarvis` when updating A record for `jarvis.makkan.homes`
subdomain=("sub1" "sub2") 
domain_id=("id1" "id2" "id3" "id4") # used in POST query as :domain_id
now=$(date -Iminutes) # keep track on when you're updating
timeout=10

tmp_file=$(mktemp)
payload_file="/tmp/payload.json"

# Usage example
function usage() {
    echo "Usage: $0 [ -d domain ] [ -s subdomain ] [ -i ids]" 1>&2
}

declare -a i_sd i_di

# Read options and corresponding values
while getopts ":d:s:i:f:h" option; do
    case "$option" in
        d) i_d="$OPTARG";;
        s) IFS=: read -ra i_sd <<< "$OPTARG";;
        i) IFS=: read -ra i_di <<< "$OPTARG";;
        f) use_defaults="$OPTARG";;
        h | \? | : | *) usage
            exit 1;;
    esac
done

if [[ -z "$use_defaults" ]]; then
  log info "Missing boolean parameter -f default.\nSet to true to assume default values else supply parameters {-d, -s, -i}"
  exit 1
fi

if [[ "$use_defaults" = false ]]; then
  if [[ -z "$i_d" ]]; then
    log info "Provide arg {-d} ..."
    exit 1
  elif [[ -z "$i_sd" ]]; then
    log info "Provide arg {-s} ..."
    exit 1
  elif [[ -z "$i_di" ]]; then
    log info "Provide arg {-i} ..."
    exit 1
  fi
    log info "Override default parameters ..."

  domain=$i_d
  log info "Setting domain = ${domain}"

  if [[ "$i_sd" = " " ]]; then
    subdomain=("")
    log info "Setting subdomain = [] i.e. on root"
  else
    subdomain=("${i_sd[@]}")
    log info "Setting subdomain = [${i_sd[*]}]"
  fi

  domain_id=("${i_di[@]}")
  log info "Setting domain id's = [${i_di[*]}]"
else
  log info "Assuming default values ..."
fi

# Get our current IP address from https://api4.my-ip.io/ip.txt
ip_addr=$(curl -s https://api.ipify.org)
CURR_EXEC="Current IP = ${ip_addr}"
log info "$CURR_EXEC"

log info "Temp file for curl output = ${tmp_file} ..."

for (( i=0; i<${#domain_id[@]}; i++ )); do
  action="retrieve"
  url="${base_url}/${action}/${domain[j]}/${domain_id[i]}"
  log info "URL = ${url}"

  cat <<-EOF > ${payload_file}
{
  "secretapikey": "${secret}",
  "apikey": "${api}"
}
EOF

  json_here_data=$(< $payload_file jq --indent 0)
  log info "Payload = ${json_here_data}"

  CURR_EXEC="Executing CURL request#(${i}) with action= ${action} for ${domain[j]},${subdomain[i]},${domain_id[i]} ..."

  curl_resp=$(curl --silent \
    --connect-timeout "$timeout" \
    --fail-with-body \
    --output "${tmp_file}" \
    --write-out "%{http_code}" \
    --header 'Content-Type: application/json' \
    --location "${url}" \
    --trace /tmp/curl.trace \
    --data "$json_here_data")

  echo "Curl Exit code: $?"

  if [[ ! "${curl_resp}" =~ ^2.. ]]; then
    log info "Update FAILED with code: ${curl_resp}"
    # log info "`cat $tmp_file`"
    log info "$(cat "$tmp_file")"
    continue
  fi

  ## 1. Get A record if response has "SUCCESS".
  ## 2. Match it against presently detected external IP address ($ip_addr) 
  ## 3. Only issue update if values are different
  ## 
  ## Note: jq query result outputs " ". Need to employ raw strings by using `-r`

  ## /1/
  CURR_EXEC="Checking curl_resp.status ..."
  log info "$CURR_EXEC"

  success=$(jq -r '.status' "$tmp_file" )
  log info "Retrive query returned = $success"

  if [[ "$success" != "SUCCESS" ]]; then
    CURR_EXEC="DNS record did not return success. Skipping ..."
    log info "$CURR_EXEC"
    log info "$(cat "$tmp_file")"
    continue
  fi
  
  ## /2/
  CURR_EXEC="Checking curl_resp.records[0].content ..."
  log info "$CURR_EXEC"

  dns_ip_entry=$(jq -r '.records[0].content' "$tmp_file")
  if [[ "$dns_ip_entry" = "$ip_addr" ]]; then
    CURR_EXEC="DNS IP entry {$dns_ip_entry} matches externally visible IP entry {$ip_addr} ..."
    log info "$CURR_EXEC"
    log info "Skipping update of ${domain[j]}/${domain_id[i]}"
    continue
  fi

  ## /3/
  # Change url to `edit' and set appropriate payload
  action="edit"
  url="${base_url}/${action}/${domain[j]}/${domain_id[i]}"

  if [[ -z "$subdomain[i]" ]]; then
    # assume operation on root domain; so don't include `name` in payload
    cat <<-EOF > ${payload_file}
{
  "secretapikey": "${secret}",
  "apikey": "${api}",
  "type": "${rec_type}",
  "content": "${ip_addr}",
  "ttl": "${ttl}"
}
EOF
  else
    # include `name` in payload
    cat <<-EOF > ${payload_file}
{
  "secretapikey": "${secret}",
  "apikey": "${api}",
  "name": "${subdomain[i]}",
  "type": "${rec_type}",
  "content": "${ip_addr}",
  "ttl": "${ttl}"
}
EOF
  fi

  CURR_EXEC="Executing CURL request#(${i}) with action= ${action} for ${domain},${subdomain[i]},${domain_id[i]} ..."
  log info "$CURR_EXEC"

  json_here_data=$(< $payload_file jq --indent 0)
  log info "URL = ${url}"
  log info "Payload = ${json_here_data}"
  
  curl_resp=$(curl --silent \
    --connect-timeout "$timeout" \
    --fail-with-body \
    --output "${tmp_file}" \
    --write-out "%{http_code}" \
    --header 'Content-Type: application/json' \
    --location "${url}" \
    --trace /tmp/curl.trace \
    --data "$json_here_data")

  echo "Curl Exit code: $?"

  if [[ ! "${curl_resp}" =~ ^2.. ]]; then
    log info "Update FAILED with code: ${curl_resp}"
    # log info "`cat $tmp_file`"
    log info "$(cat $tmp_file)"
  else
    CURR_EXEC="Updated record for makkan.homes to ${ip_addr} at ${now}"
    log info "${CURR_EXEC}"
  fi
done
