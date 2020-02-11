#!/bin/bash -xe

# Allows this script to be invoked from any directory:
cd $(dirname "$0")

REPO_ROOT_DIR=../..


DB_HOSTNAME=$(jq -r '.["db-hostname"]' $REPO_ROOT_DIR/../circleci-failure-tracker-credentials/database-credentials-remote.json)



NEW_FILE=$(mktemp)
./generate_config_yml.py > $NEW_FILE

pg_dump -h $DB_HOSTNAME --create -s -U postgres -d loganci > $NEW_FILE

mv $NEW_FILE $REPO_ROOT_DIR/configuration/schema.sql
