#!/bin/bash
set -e

. /opt/bitnami/scripts/libvalidations.sh

if ! is_boolean_yes "$LDAP_READONLY_USER"; then
  exit 0
fi

FILE="${LDAP_SHARE_DIR}/readonly-user-acl.ldif"

cat > "${FILE}" << EOF
dn: olcDatabase={2}${LDAP_BACKEND},cn=config
changetype: modify
delete: olcAccess
-
add: olcAccess
olcAccess: to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break
olcAccess: to attrs=userPassword,shadowLastChange by self write by dn="cn=admin,${LDAP_ROOT_DN}" write by anonymous auth by * none
olcAccess: to * by self read by dn="cn=admin,${LDAP_ROOT_DN}" write by dn="cn=${LDAP_READONLY_USER_USERNAME},${LDAP_ROOT_DN}" read by * none
EOF

debug_execute ldapmodify -Y EXTERNAL -H "ldapi:///" -f "${FILE}"
