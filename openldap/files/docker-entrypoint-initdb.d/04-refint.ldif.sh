#!/bin/bash
set -e

. /opt/bitnami/scripts/libvalidations.sh

FILE="${LDAP_CUSTOM_LDIF_DIR}/04-refint.ldif"

cat > "${FILE}" << EOF
# Load refint module
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: refint

# Backend refint overlay
dn: olcOverlay={1}refint,olcDatabase={2}${LDAP_BACKEND},cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcRefintConfig
olcOverlay: {1}refint
olcRefintAttribute: owner
olcRefintAttribute: manager
olcRefintAttribute: uniqueMember
olcRefintAttribute: member
olcRefintAttribute: memberOf
EOF
