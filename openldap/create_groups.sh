export ADMIN='TMZC6jeCSzIv8O9A'
export CONFIG_ADMIN='dD/vKiemIvpr6KXl'
export READ_ONLY='aOF6ewhgvTarYdZv'

cat > add-ldap-entries.sh << 'EOF'
#!/bin/bash

ldapadd -H ldap://localhost:3890 -x -D "cn=admin,dc=muellerpublic,dc=de" -w "$ADMIN" << LDIF
dn: uid=erwin,ou=users,dc=muellerpublic,dc=de
uid: erwin
objectClass: inetOrgPerson
mail: erwin@muellerpublic.de
sn:: TcO8bGxlcg==
userPassword:: e0FSR09OMn0kYXJnb24yaWQkdj0xOSRtPTcxNjgsdD01LHA9MSQvNVJmU1NnQUdhTkpSbW0zUFRBMjN3JGEzM0IyU3Y5MWNaOWlHMjcyYzl5bytiK04yMFE0RHpnN3BxVmplUmFvQXMA
cn: Erwin

# Create groups
dn: cn=admins,ou=groups,dc=muellerpublic,dc=de
objectClass: groupOfNames
cn: admins
member: uid=erwin,ou=users,dc=muellerpublic,dc=de

dn: cn=grafana,ou=groups,dc=muellerpublic,dc=de
objectClass: groupOfNames
cn: grafana
member: uid=erwin,ou=users,dc=muellerpublic,dc=de

dn: cn=minio,ou=groups,dc=muellerpublic,dc=de
objectClass: groupOfNames
cn: minio
member: uid=erwin,ou=users,dc=muellerpublic,dc=de

dn: cn=jenkins,ou=groups,dc=muellerpublic,dc=de
objectClass: groupOfNames
cn: jenkins
member: uid=erwin,ou=users,dc=muellerpublic,dc=de
LDIF
EOF
