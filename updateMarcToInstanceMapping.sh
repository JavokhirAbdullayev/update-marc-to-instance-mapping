#!/bin/bash
function main() {

  total_count=0
  total_succeeded_count=0
  total_error_count=0

  local okapi_url=$1
  local tenant=$2
  local username=$3
  local password=$4
  local limit=$5
  local release=$6

  if [[ -z "$okapi_url" ]]
  then
    read -p "Enter Okapi URL: " okapi_url
    if [[ -z "$okapi_url" ]]
    then
      echo "Okapi URL cannot be empty."
      return 1
    fi
  fi

  if [[ -z "$tenant" ]]
  then
    read -p "Enter Okapi tenant: " tenant
    if [[ -z "$tenant" ]]
    then
      echo "Okapi tenant cannot be empty."
      return 1
    fi
  fi

  if [[ -z "$username" ]]
  then
    read -p "Enter admin username: " username
    if [[ -z "$username" ]]
    then
      echo "Username cannot be empty."
      return 1
    fi
  fi

  if [[ -z "$password" ]]
  then
    read -s -p "Enter admin password: " password
    echo
    if [[ -z "$password" ]]
    then
      echo "Password cannot be empty."
      return 1
    fi
  fi

  if [[ -z "$limit" ]]
  then
    read -p "Enter limit number: " limit
  fi

  if [[ -z "$release" ]]
  then
    read -p "Enter release version (0 - Kiwi, 1 - Lotus and higher): " release
    if [[ -z "$release" ]]
    then
      release=1
    fi
  fi

  # Login by admin
  login_body="{\"username\":\"${username}\",\"password\":\"${password}\"}"
  login_url="${okapi_url}/authn/login"

  token=$(curl -X POST "${login_url}" --silent \
  	-H "X-Okapi-Tenant: $tenant" \
  	-H "Content-Type: application/json" \
  	-d "${login_body}" | awk 'BEGIN { FS="\""; RS="," }; { if ($2 == "okapiToken") {print $4} }')

  if [[ -z $token ]]
  then
    echo "Cannot login. Shutting down the script."
    return 1
  fi

  # GET Instances count
  get_instances_count_url="${okapi_url}/instance-storage/instances?limit=0"

  total_records=$(curl -X GET "${get_instances_count_url}" --silent \
    -H "X-Okapi-Tenant: $tenant" \
    -H "X-Okapi-Token: $token" \
    -H "Content-Type: application/json" | awk 'BEGIN { FS="\"totalRecords\": "; RS="," }; { print $2 }')

  # Trim total records to remove spaces from integer value
  total_records=$(echo $total_records | tr -d ' ')

  if [[ $total_records -le 0 ]]
  then
    echo "The number of total records is equal to 0."
    exit 1
  fi

  if [[ -z $limit ]]
  then
    limit=$total_records
  fi

  # Offset set up
  if [ -f "offset.txt" ]; then
      offset=$(<offset.txt)
  fi

  if [[ -z $offset ]]
  then
    offset=0
    echo "$offset" > offset.txt
  fi

  # GET All Instance ids
  get_all_instance_ids_url="${okapi_url}/instance-storage/instances?limit=${limit}&offset=${offset}"
  get_all_instance_ids_url=$(echo $get_all_instance_ids_url | tr -d ' ')

  instances=$(curl -X GET "${get_all_instance_ids_url}" --silent \
    -H "X-Okapi-Tenant: $tenant" \
    -H "X-Okapi-Token: $token" \
    -H "Content-Type: application/json" |
    jq -r '.instances[] | select(.source=="MARC") | .id + "," + (._version|tostring)')

  read -a instances <<< $instances

  total_count=${#instances[@]}

  for i in "${instances[@]}"
  do
    instance_id="$(cut -d',' -f1 <<< $i)"
    version="$(cut -d',' -f2 <<< $i)"
    processMarcRecord $okapi_url $tenant $token $instance_id $version $release
  done

  # Reset offset if there are no records left
  if [[ $offset -ge $total_records ]]
  then
    offset=0
  else
    offset=$((offset+limit))
  fi

  echo "$offset" > offset.txt

  echo "Total count: $total_count, Total succeeded count: $total_succeeded_count, Total error count: $total_error_count"

}

function processMarcRecord() {

  local okapi_url=$1
  local tenant=$2
  local token=$3
  local instance_id=$4
  local version=$5
  local release=$6

  # GET SRS MARC-Bib Record
  get_srs_marc_record_url="${okapi_url}/change-manager/parsedRecords?externalId=${instance_id}"

  local change_manager_body=$(curl -X GET "${get_srs_marc_record_url}" --silent \
    -H "X-Okapi-Tenant: $tenant" \
    -H "X-Okapi-Token: $token" \
    -H "Content-Type: application/json")

  if jq -e . >/dev/null 2>&1 <<< "$change_manager_body"; then
    if [[ "$release" -eq 1 ]]
    then
      change_manager_body="$(jq --arg version "$version" '. += {"relatedRecordVersion":$version}' <<< $change_manager_body)"
    fi
  else
    total_error_count=$((total_error_count+1))
    echo "$instance_id" - "$change_manager_body" >> results.txt
    return 1
  fi

  local record_id="$(jq -r '. .id' <<< "$change_manager_body")"

  if [[ -z "$record_id" ]]
  then
    total_error_count=$((total_error_count+1))
    echo "$instance_id" - "RecordId is empty" >> results.txt
    return 1
  fi

  # PUT SRS MARC-Bib Record
  put_srs_marc_record_url="${okapi_url}/change-manager/parsedRecords/${record_id}"

  local response=$(curl -X PUT "${put_srs_marc_record_url}" --silent \
    -H "X-Okapi-Tenant: $tenant" \
    -H "X-Okapi-Token: $token" \
    -H "Content-Type: application/json" \
    -w "%{http_code}\n" \
    -d "${change_manager_body}")

  if [[ $response == "202" ]]
  then
    total_succeeded_count=$((total_succeeded_count+1))
  else
    total_error_count=$((total_error_count+1))
  fi
  echo "$instance_id" - "ok" >> results.txt
}

# Main entry point
SECONDS=0

main $1 $2 $3 $4 $5 $6

duration=$SECONDS
echo "$(( $duration / 3600 )) hours, $((( $duration / 60 ) % 60 )) minutes and $(( $duration % 60 )) seconds elapsed."
