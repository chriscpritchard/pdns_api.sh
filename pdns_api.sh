#!/usr/bin/env bash

# Copyright 2016 - Silke Hofstra
#
# Licensed under the EUPL, Version 1.1 or -- as soon they will be approved by
# the European Commission -- subsequent versions of the EUPL (the "Licence");
# You may not use this work except in compliance with the Licence.
# You may obtain a copy of the Licence at:
#
# https://joinup.ec.europa.eu/software/page/eupl
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the Licence is distributed on an "AS IS" basis,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied.
# See the Licence for the specific language governing
# permissions and limitations under the Licence.
#

set -e
set -u
set -o pipefail

# Local directory
DIR="$(dirname "$0")"

# Config directories
CONFIG_DIRS="/etc/dehydrated /usr/local/etc/dehydrated"

# Show an error/warning
error() { echo "Error: $*" >&2; }
warn() { echo "Warning: $*" >&2; }
fatalerror() { error "$*"; exit 1; }

# Debug message
debug() { [[ -z "${DEBUG:-}" ]] || echo "$@"; }

# Join an array with a character
join() { local IFS="$1"; shift; echo "$*"; }

# Reverse a string
rev() {
  local str rev
  str="$(cat)"
  rev=""
  for (( i=${#str}-1; i>=0; i-- )); do rev="${rev}${str:$i:1}"; done
  echo "${rev}"
}

# Different sed version for different os types...
# From letsencrypt.sh
_sed() {
  if [[ "${OSTYPE}" = "Linux" ]]; then
    sed -r "${@}"
  else
    sed -E "${@}"
  fi
}

# Get string value from json dictionary
# From letsencrypt.sh
get_json_string_value() {
  local filter
  filter="$(printf 's/.*"%s": *"([^"]*)".*/\\1/p' "$1")"
  _sed -n "${filter}"
}

# Get integer value from json dictionary
get_json_int_value() {
  local filter
  filter="$(printf 's/.*"%s": *([^,}]*),*.*/\\1/p' "$1")"
  _sed -n "${filter}"
}

# Load the configuration and set default values
load_config() {
  # Check for config in various locations
  # From letsencrypt.sh
  if [[ -z "${CONFIG:-}" ]]; then
    for check_config in ${CONFIG_DIRS} "${PWD}" "${DIR}"; do
      if [[ -f "${check_config}/config" ]]; then
        CONFIG="${check_config}/config"
        break
      fi
    done
  fi

  # Default values
  PDNS_PORT=8081

  # Check if config was set
  if [[ -z "${CONFIG:-}" ]]; then
    # Warn about missing config
    warn "No config file found, using default config!"
  elif [[ -f "${CONFIG}" ]]; then
    # shellcheck disable=SC1090
    . "${CONFIG}"
  fi

  # Check required settings
  [[ -n "${PDNS_HOST:-}" ]] || fatalerror "PDNS_HOST setting is required."
  [[ -n "${PDNS_KEY:-}" ]]  || fatalerror "PDNS_KEY setting is required."
}

# Load the zones from file
load_zones() {
  # Check for zones.txt in various locations
  if [[ -z "${PDNS_ZONES_TXT:-}" ]]; then
    for check_zones in ${CONFIG_DIRS} "${PWD}" "${DIR}"; do
      if [[ -f "${check_zones}/zones.txt" ]]; then
        PDNS_ZONES_TXT="${check_zones}/zones.txt"
        break
      fi
    done
  fi

  # Load zones
  all_zones=""
  if [[ -n "${PDNS_ZONES_TXT:-}" ]] && [[ -f "${PDNS_ZONES_TXT}" ]]; then
    all_zones="$(cat "${PDNS_ZONES_TXT}")"
  fi
}

# API request
request() {
  # Request parameters
  local method url data
  method="$1"
  url="$2"
  data="$3"

  # Do the request
  res="$(curl -sS --request "${method}" --header "${headers}" --data "${data}" "${url}")"

  # Debug output
  debug "Method: ${method}"
  debug "URL: ${url}"
  debug "Data: ${data}"
  debug "Response: ${res}"

  # Abort on failed request
  if [[ "${res}" = *"error"* ]] || [[ "${res}" = "Not Found" ]]; then
    error "API error: ${res}"
    exit 1
  fi
}

# Setup of connection settings
setup() {
  # Header with the api key
  headers="X-API-Key: ${PDNS_KEY}"

  # Add the host and port to the url
  url="http://${PDNS_HOST}:${PDNS_PORT}"

  # Detect the version
  if [[ -z "${PDNS_VERSION:-}" ]]; then
    request "GET" "${url}/api" ""
    PDNS_VERSION="$(<<< "${res}" get_json_int_value version)"
  fi

  # Fallback to version 0
  if [[ -z "${PDNS_VERSION}" ]]; then
    PDNS_VERSION=0
  fi

  # Some version incompatibilities
  if [[ "${PDNS_VERSION}" -ge 1 ]]; then
    url="${url}/api/v${PDNS_VERSION}"
  fi

  # Detect the server
  if [[ -z "${PDNS_SERVER:-}" ]]; then
    request "GET" "${url}/servers" ""
    PDNS_SERVER="$(<<< "${res}" get_json_string_value id)"
  fi

  # Fallback to localhost
  if [[ -z "${PDNS_SERVER}" ]]; then
    PDNS_SERVER="localhost"
  fi

  # Zone endpoint on the API
  url="${url}/servers/${PDNS_SERVER}/zones"

  # Get a zone list from the API is none was set
  if [[ -z "${all_zones}" ]]; then
    request "GET" "${url}" ""
    all_zones="$(<<< "${res//, /$',\n'}" get_json_string_value name)"
  fi

  # Strip trailing dots from zones
  all_zones="${all_zones//$'.\n'/ }"
  all_zones="${all_zones%.}"

  # Sort zones to list most specific first
  all_zones="$(<<< "${all_zones}" rev | sort | rev)"
}

setup_domain() {
  # Domain and token from arguments
  domain="$1"
  token="$2"
  zone=""

  #record name
  if [[ "${domain}" =~ ^[*]\.([^*]+) ]]; then
        rootdomain="${BASH_REMATCH[1]}"
	wildcard=true
        name="_acme-challenge.${rootdomain}"
	#warn "domain is a wildcard domain, acme challenge will be for ${name}"
  else
        name="_acme-challenge.${domain}"
  fi

  # Read name parts into array
  IFS='.' read -ra name_array <<< "${name}"

  # Find zone name, cut off subdomains until match
  for check_zone in ${all_zones}; do
    for (( j=${#name_array[@]}-1; j>=0; j-- )); do
      if [[ "${check_zone}" = "$(join . "${name_array[@]:j}")" ]]; then
        zone="${check_zone}"
        break 2
      fi
    done
  done

  # Fallback to creating zone from arguments
  if [[ -z "${zone}" ]]; then
    zone="${name_array[*]: -2:1}.${name_array[*]: -1:1}"
    warn "zone not found, using '${zone}'"
  fi

  # Some version incompatibilities
  if [[ "${PDNS_VERSION}" -ge 1 ]]; then
    name="${name}."
    zone="${zone}."
    extra_data=""
  else
    extra_data=",\"name\": \"${name}\", \"type\": \"TXT\", \"ttl\": 1"
  fi
}

deploy_rrset() {
  echo '{
    "name": "'"${name}"'",
    "type": "TXT",
    "ttl": 1,
    "records": [{
      "content": "\"'"${token}"'\"",
      "disabled": false,
      "set-ptr": false
      '"${extra_data}"'
    }],
    "changetype": "REPLACE"
  }'
}

clean_rrset() {
  echo '{"name":"'"${name}"'","type":"TXT","changetype":"DELETE"}'
}

soa_edit() {
  # Show help
  if [[ $# -eq 0 ]]; then
    echo "Usage: pdns_api.sh soa_edit <zone> [SOA-EDIT] [SOA-EDIT-API]"
    exit 1
  fi

  # Get current values for zone
  request "GET" "${url}/$1" ""

  # Set variables
  if [[ $# -le 1 ]]; then
    soa_edit=$(<<< "${res}" get_json_string_value soa_edit)
    soa_edit_api=$(<<< "${res}" get_json_string_value soa_edit_api)

    echo "Current values:"
  else
    soa_edit="$2"
    if [[ $# -eq 3 ]]; then
      soa_edit_api="$3"
    else
      soa_edit_api="$2"
    fi

    echo "Setting:"
  fi

  # Display values
  echo "SOA-EDIT:     ${soa_edit}"
  echo "SOA-EDIT-API: ${soa_edit_api}"

  # Update values
  if [[ $# -eq 2 ]]; then
    request "PUT" "${url}/${1}" '{
      "soa_edit":"'"${soa_edit}"'",
      "soa_edit_api":"'"${soa_edit_api}"'",
      "kind":"'"$(<<< "${res}" get_json_string_value kind)"'"
    }'
  fi
}

exit_hook() {
  if [[ ! -z "${PDNS_EXIT_HOOK:-}" ]]; then
      if [[ -x "${PDNS_EXIT_HOOK}" ]]; then
        exec "${PDNS_EXIT_HOOK}"
      else
        error "${PDNS_EXIT_HOOK} is not an executable"
        exit 1
      fi
  fi
}

main() {
  # Set hook
  hook="$1"

  # Debug output
  debug "Hook: ${hook}"

  # Deployment of a certificate
  if [[ "${hook}" = "deploy_cert" ]]; then
    exit 0
  fi

  # Unchanged certificate
  if [[ "${hook}" = "unchanged_cert" ]]; then
    exit 0
  fi

  # Main setup
  load_config
  load_zones
  setup
  declare -A requests

  # Interface for SOA-EDIT
  if [[ "${hook}" = "soa_edit" ]]; then
    shift
    soa_edit $@
    exit 0
  fi

  # Interface for exit_hook
  if [[ "${hook}" = "exit_hook" ]]; then
    shift
    exit_hook "$@"
    exit 0
  fi

  # Loop through arguments per 3
  for ((i=2; i<=$#; i=i+3)); do
    # Setup for this domain
    req=""
    t=$((i + 2))
    setup_domain "${!i}" "${!t}"

    # Debug output
    debug "Name:  ${name}"
    debug "Token: ${token}"
    debug "Zone:  ${zone}"

    # Add comma
    if [[ ${requests[${zone}]+x} ]]; then
      req="${requests[${zone}]},"
    fi

    # Deploy a token
    if [[ "${hook}" = "deploy_challenge" ]]; then
      if [[ $wildcard = true ]]; then
      	warn "domain is a wildcard domain, acme challenge will be for ${name}"
      fi
      requests[${zone}]="${req}$(deploy_rrset)"
    fi

    # Remove a token
    if [[ "${hook}" = "clean_challenge" ]]; then
      requests[${zone}]="${req}$(clean_rrset)"
    fi

    # Other actions are not implemented but will not cause an error
  done

  # Perform requests
  for zone in "${!requests[@]}"; do
    request "PATCH" "${url}/${zone}" '{"rrsets": ['"${requests[${zone}]}"']}'
  done

  # Wait the requested amount of seconds when deployed
  if [[ "${hook}" = "deploy_challenge" ]] && [[ -n "${PDNS_WAIT:-}" ]]; then
    debug "Waiting for ${PDNS_WAIT} seconds"

    sleep "${PDNS_WAIT}"
  fi
}

main "$@"
