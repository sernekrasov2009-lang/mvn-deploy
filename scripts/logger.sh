#!/bin/bash

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
RESET="\033[0m"


log_ok() {
    echo -e "${GREEN}[✓]${RESET} $1"
}


log_info() {
    echo -e "[+] $1"
}


log_warn() {
    echo -e "${YELLOW}[!]${RESET} $1"
}


log_error() {
    echo -e "${RED}[✗]${RESET} $1"
}
