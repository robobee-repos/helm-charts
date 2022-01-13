#!/bin/bash
set -e

. /opt/bitnami/scripts/libvalidations.sh

FILE="${LDAP_CUSTOM_LDIF_DIR}/03-memberOf.ldif"

cat > "${FILE}" << EOF
# Load memberof module
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: memberof

# Backend memberOf overlay
dn: olcOverlay={0}memberof,olcDatabase={2}${LDAP_BACKEND},cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcMemberOf
olcOverlay: {0}memberof
olcMemberOfDangling: ignore
olcMemberOfRefInt: TRUE
olcMemberOfGroupOC: groupOfUniqueNames
olcMemberOfMemberAD: uniqueMember
olcMemberOfMemberOfAD: memberOf
EOF
