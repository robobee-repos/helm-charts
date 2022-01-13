#!/bin/bash

. /opt/bitnami/scripts/libvalidations.sh

if ! is_boolean_yes "$LDAP_READONLY_USER"; then
  exit 0
fi

LDAP_READONLY_USER_PASSWORD_ENCRYPTED="$(echo -n $LDAP_READONLY_USER_PASSWORD |
 slappasswd -n -T /dev/stdin)"

cat << "EOF"
# Paths
dn: cn=${LDAP_READONLY_USER_USERNAME},${LDAP_ROOT_DN}
changetype: add
cn: ${LDAP_READONLY_USER_USERNAME}
objectClass: simpleSecurityObject
objectClass: organizationalRole
userPassword: ${LDAP_READONLY_USER_PASSWORD_ENCRYPTED}
description: LDAP read only user
EOF
