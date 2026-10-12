#!/bin/bash

set -e

echo "[DEPS] Installing dependencies..."


apt update


apt install -y \
curl \
wget \
jq \
unzip \
openssl \
qrencode


echo "[DEPS] Done"
