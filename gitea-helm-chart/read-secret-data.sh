#!/bin/bash

set -e

secret=`cat db-secret.json`

for v in `echo $secret | jq -r '.data | keys[] as $k | "{\"\($k)\":\"\(.[$k])\"}"'`; do 
    key=`echo "$v" | jq -r 'keys[]'`; value=`echo "$v" | jq -r 'values[]'`
    declare -A map
    map[$key]="`echo $value | base64 -d`"
done

echo "${map['host']}:${map['port']}"
