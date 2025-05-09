#!/bin/bash
if [[ $# -eq 0 ]] ; then
    echo 'You need to provide your network name'
    exit 0
fi
netname=$1
export LOCAL_IP=$(ip addr show $netname  | awk '$1 == "inet" { print $2 }' | cut -d/ -f1)

sed -i "/INTERNAL_IP/c INTERNAL_IP=$LOCAL_IP" .env
sed -i "/KAFKA_ADDRESS/c KAFKA_ADDRESS=$LOCAL_IP" .env

# Function for countdown with progress logging
countdown() {
    local seconds=$1
    local message=${2:-"Waiting"}
    echo "$message: $seconds seconds remaining..."
    for i in $(seq $seconds -1 1); do
        echo -ne "\r$message: $i seconds remaining..."
        sleep 1
    done
    echo -e "\r$message: Complete!            "
}
# Function to copy and import JSON files to MongoDB
import_mongo_file() {
    local file=$1
    local collection=$2
    echo "Importing $file into $collection collection..."
    docker cp tenant/$file mongo:/tmp/$file
    docker compose exec -T mongo mongoimport --uri "mongodb://admin:control123!@localhost:27017/viz_root?authSource=admin" \
        --collection $collection --file /tmp/$file --mode upsert
}


echo 'Fix consul permissions'
mkdir -p ./compose-data/consul
sudo chown -R 100:100 ./compose-data/consul

docker compose up -d consul zookeeper  mongo  && countdown 10 "Starting consul zookeeper mongo and kafka"
docker compose up -d kafka  && countdown 40 "Waiting for kafka to start"
docker compose up -d keycloak iam-config  && countdown 10 "Staring keycloak and iam-config"
docker compose up -d services && countdown 180 "Starting Services & Migrating Data"

echo 'Import Consul Configuration File for Project Under Test'
docker cp consul_config.json consul:/consul_config.json
docker compose exec -T consul /bin/consul kv import @consul_config.json

docker compose up -d iot-rest-connector rpin
docker compose up -d transformbridge ytem-transaction-tracker
docker compose up -d mongoinjector reportgenerator
docker compose up -d sysconfig-web
docker compose stop services
docker compose stop keycloak iam-config # we can do this later
####countdown 60 'Waiting for ingestion data consume'

docker compose up -d minio
docker compose up -d ytem-locations ytem-site-provisioner && countdown 60 "Waiting for ytem-locations sysconfig-web ytem-site-provisioner"

echo 'Import tenant data to mongo'
import_mongo_file "transactions_PERN.json" "transactions"
import_mongo_file "transactions_detail_PERN.json" "transactiondetail"
import_mongo_file "creation_PERN.json" "tenant_creation_request"

####countdown 30 'Waiting for tenant creation initialization'
####echo 'Monitoring sysconfig-web logs...'
####countdown 5 'Additional wait single attempt'
####timeout -k 5 60 sudo tail -n 200 -f ./compose-data/sysconfig-web/tmp/output_SYSCONFIG_PERN* || echo "No logs detected after 60 seconds timeout"

# starting services to install license
####docker compose up -d services

####countdown 120 'Waiting Complementary task in tenant creation'

### wait for sysconfig-web to finish
# Set up a polling loop to check the status
echo "Polling for transaction status (waiting for SUCCESS or ERROR)..."
max_attempts=180
attempt=1
# Initialize status to something other than the final states
transaction_status="UNKNOWN" # Use a different variable name to avoid confusion with loop variable 'status'
status_code=0 # Initialize status_code

while [ $attempt -le $max_attempts ]; do
  echo "Attempt $attempt of $max_attempts..."

  # Execute curl with silent mode and capture status code
  response=$(curl -s --location 'http://localhost:8480/statemachine-api-configuration/rest/configuration/locations/transactions/681a275e50fa74419a765cdf' \
    --header 'Content-Type: application/json' \
    --header 'apikey: 7B4BCCDC' \
    --header 'tenant: root' \
    --header 'accept-version: v2' \
    -w "\n%{http_code}")

  # Extract status code from the last line
  status_code=$(echo "$response" | tail -n1)
  # Extract the response body (everything except the last line)
  body=$(echo "$response" | sed '$d')

  parsed_status=$(echo "$body" | jq -r '.[0].status')
  jq_exit_status=$?

  # Check for HTTP errors first
  if [ "$status_code" -ne 200 ]; then
    echo "ERROR: Received non-200 status code: $status_code" >&2 # Output error to stderr
    echo "Response Body: $body" >&2
    transaction_status="HTTP_ERROR" # Set status to indicate failure
    break # Exit loop on HTTP error
  elif [ $jq_exit_status -ne 0 ]; then
      echo "ERROR: Failed to parse JSON body or find .[0].status key with jq." >&2
      echo "Response Body: $body" >&2
      transaction_status="PARSE_ERROR" # Set status to indicate failure
      break # Exit loop on parsing error
  fi

  # Now check the reliably parsed status
  if [ "$parsed_status" = "SUCCESS" ]; then
    transaction_status="SUCCESS"
    echo "Status is now SUCCESS!"
    echo "$body" # Optional: print the final success body
    break # Exit loop on success
  elif [ "$parsed_status" = "ERROR" ]; then
    transaction_status="ERROR"
    echo "Status is now ERROR!"
    echo "$body" # Optional: print the error body
    break # Exit loop on reported error status
  else
    # Status is something else (like IN_PROGRESS, PENDING, etc.)
    echo "Status: $parsed_status. Waiting before next attempt..."
    countdown 5 "Waiting for next attempt"
  fi

  attempt=$((attempt+1))
  sudo tail -n 10 ./compose-data/sysconfig-web/tmp/output_SYSCONFIG_PERN* || echo "No logs detected after 60 seconds timeout"
  # if attempt is equals to 10 we proceed to start services
  if [ $attempt -eq 10 ]; then
    echo "Attempting to start services after 10 attempts..."
    docker compose up -d services
  fi
done

echo "Polling finished."

if [ "$transaction_status" = "SUCCESS" ]; then
  echo "Transaction completed successfully."
elif [ "$transaction_status" = "ERROR" ]; then
  echo "Transaction reported an ERROR status."
elif [ "$transaction_status" = "HTTP_ERROR" ]; then
  echo "Polling failed due to an HTTP error ($status_code)."
elif [ "$transaction_status" = "PARSE_ERROR" ]; then
  echo "Polling failed due to a JSON parsing error."
elif [ $attempt -gt $max_attempts ]; then
   # This case is technically covered by the loop condition and the checks inside,
   # but as a fallback check: if loop exited because attempts ran out
  echo "Maximum polling attempts reached ($max_attempts). Transaction did not reach SUCCESS or ERROR state."
else
  # Should not happen if logic is sound, but good for debugging
  echo "Polling loop exited unexpectedly. Final status: $transaction_status"
fi
### wait for sysconfig-web to finish

docker compose logs
echo 'Environment is ready, you can turn on the applications'

echo 'Creating MySQL database backup...'
backup_file="mysql_backup.sql"
docker compose exec -T mysql sh -c 'exec mysqldump --all-databases -u root -pcontrol123!' > "$backup_file"
echo "MySQL backup completed: $backup_file"
tar -cvf "$backup_file.tar" "$backup_file"

