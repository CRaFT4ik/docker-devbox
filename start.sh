#!/bin/bash

docker compose up -d
docker exec -it -u corp devbox zsh
