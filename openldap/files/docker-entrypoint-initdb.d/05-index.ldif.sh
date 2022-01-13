#!/bin/bash
set -e

. /opt/bitnami/scripts/libvalidations.sh

FILE="${LDAP_CUSTOM_LDIF_DIR}/05-index.ldif"

cat > "${FILE}" << EOF
# Add indexes
dn: olcDatabase={2}${LDAP_BACKEND},cn=config
changetype:  modify
replace: olcDbIndex
olcDbIndex: uid eq
olcDbIndex: mail eq
olcDbIndex: memberOf eq
olcDbIndex: entryCSN eq
olcDbIndex: entryUUID eq
olcDbIndex: objectClass eq
EOF
