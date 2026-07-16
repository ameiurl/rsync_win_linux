#!/bin/bash

set -e

if [ -z $1 ]; then
	echo "Error! Missing syncd config name."
	exit 1
fi

if [ -z $2 ]; then
	echo "Error! Missing command to run after starting syncd."
	exit 1
fi

syncd $1 start

exec "${@:2}"