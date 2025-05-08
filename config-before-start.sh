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
countdown 60 'Waiting for ingestion data consume'

docker compose up -d minio
docker compose up -d ytem-locations ytem-site-provisioner && countdown 60 "Waiting for ytem-locations sysconfig-web ytem-site-provisioner"

echo 'Import tenant data to mongo'
import_mongo_file "transactions_PERN.json" "transactions"
import_mongo_file "transactions_detail_PERN.json" "transactiondetail"
import_mongo_file "creation_PERN.json" "tenant_creation_request"

countdown 30 'Waiting for tenant creation initialization'
echo 'Monitoring sysconfig-web logs...'
timeout -k 5 60 docker compose exec -T sysconfig-web tail -n 200 -f /tmp/* || echo "No logs detected after 60 seconds timeout"
timeout -k 5 60 docker compose exec -T sysconfig-web tail -n 200 -f /tmp/output_SYSCONFIG_PERN* || echo "No logs detected after 60 seconds timeout"

countdown 120 'Waiting Complementary task in tenant creation'

docker compose logs
echo 'Environment is ready, you can turn on the applications'
