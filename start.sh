#!/bin/bash
set -e

cd "$(dirname "$0")"
[ -f .env ] && . ./.env   # DEV_USER lives there, same file compose reads

docker compose up -d
docker exec -it -u "${DEV_USER:?not set — define DEV_USER in .env}" devbox zsh
