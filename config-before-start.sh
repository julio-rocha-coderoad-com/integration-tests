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


echo 'Fix consul permissions'
mkdir -p ./compose-data/consul
sudo chown -R 100:100 ./compose-data/consul

docker compose up -d consul zookeeper  mongo  && countdown 10 "Starting consul zookeeper mongo and kafka"
docker compose up -d kafka  && countdown 40 "Waiting for kafka to start"
docker compose up -d keycloak iam-config  && countdown 10 "Staring keycloak and iam-config"
docker compose up -d services && countdown 180 "Starting Services & Migrating Data"
echo 'Stopping services' && docker compose stop services

docker compose up -d iot-rest-connector rpin transformbridge ytem-transaction-tracker mongoinjector reportgenerator
countdown 120 'Waiting for ingestion data consume'

docker compose logs
echo 'Environment is ready, you can turn on the applications'
