#!/bin/bash

if [ "$V_ATTEST_MODE" = "server" ]; then
	RUN_DIR="/run/v-attest-server"
else
	V_ATTEST_MODE="client"
	RUN_DIR="/run/v-attest"
fi

VAR_DIR="/var/lib/attest-server"
