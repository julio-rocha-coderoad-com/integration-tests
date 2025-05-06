#!/bin/bash
if [[ $# -eq 0 ]] ; then
    echo 'You need to provide your network name'
    exit 0
fi
netname=$1
export LOCAL_IP=$(ip addr show $netname  | awk '$1 == "inet" { print $2 }' | cut -d/ -f1)

sed -i "/INTERNAL_IP/c INTERNAL_IP=$LOCAL_IP" .env
sed -i "/KAFKA_ADDRESS/c KAFKA_ADDRESS=$LOCAL_IP" .env

echo 'Fix consul permissions'
mkdir -p ./compose-data/consul
sudo chown -R 100:100 ./compose-data/consul

echo 'Starting consul zookeeper mongo and kafka'
docker compose up -d consul zookeeper  mongo  && sleep 10
docker compose up -d kafka  && sleep 10

echo 'Staring keycloak and iam-config'
docker compose up -d keycloak iam-config  && sleep 10

echo 'Starting services'
docker compose up -d services && sleep 180
echo 'Stopping services'
docker compose stop services

echo 'Turn on ingestion applications'
docker compose up -d iot-rest-connector rpin transformbridge ytem-transaction-tracker mongoinjector reportgenerator
echo 'Waiting 120 seconds to let ingestion consume data'
sleep 120

docker compose logs
echo 'Environment is ready, you can turn on the applications'
