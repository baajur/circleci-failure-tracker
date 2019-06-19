#!/bin/bash -xe

GITHUB_CLIENT_ID=$1
GITHUB_CLIENT_SECRET=$2
GITHUB_PERSONAL_ACCESS_TOKEN=$3
GITHUB_WEBHOOK_SECRET=$4
DB_HOSTNAME=$5
DB_PASSWORD=$6
ADMIN_PASSWORD=$7

find -name "*.tix" -delete

stack run my-webapp -- --local --data-path static --github-client-id $GITHUB_CLIENT_ID --github-client-secret $GITHUB_CLIENT_SECRET --github-personal-access-token $GITHUB_PERSONAL_ACCESS_TOKEN --github-webhook-secret $GITHUB_WEBHOOK_SECRET --db-hostname $DB_HOSTNAME --db-password $DB_PASSWORD --admin-password $ADMIN_PASSWORD
