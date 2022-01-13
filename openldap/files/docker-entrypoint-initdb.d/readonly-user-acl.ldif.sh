#!/bin/bash
set -e

. /opt/bitnami/scripts/libvalidations.sh

if ! is_boolean_yes "$LDAP_READONLY_USER"; then
  exit 0
fi
if [ ! -d "${LDAP_CUSTOM_LDIF_DIR}" ]; then
  mkdir -p "${LDAP_CUSTOM_LDIF_DIR}"
fi

FILE="${LDAP_CUSTOM_LDIF_DIR}/readonly-user-acl.ldif"

cat > "${FILE}" << EOF
dn: olcDatabase={2}${LDAP_BACKEND},cn=config
changetype: modify
delete: olcAccess
-
add: olcAccess
olcAccess: to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break
olcAccess: to attrs=userPassword,shadowLastChange by self write by dn="cn=admin,${LDAP_ROOT}" write by anonymous auth by * none
olcAccess: to * by self read by dn="cn=admin,${LDAP_ROOT}" write by dn="cn=${LDAP_READONLY_USER_USERNAME},${LDAP_ROOT}" read by * none
EOF
