#!/usr/bin/env bash

LDAP_URI="${LDAP_URI:-ldap://127.0.0.1:30389}"
LDAP_BIND_DN="${LDAP_BIND_DN}"
LDAP_BIND_PW="${LDAP_BIND_PW}"

BASE_DN="dc=petra,dc=ac,dc=id"
ROLES_DN="ou=roles,ou=groups,$BASE_DN"

TMP=/tmp/petra_sync_roles.ldif
> $TMP

roles=("student" "staff" "alumni" "external")

declare -A user_roles

for role in "${roles[@]}"; do

ldapsearch -LLL -x \
-H "$LDAP_URI" \
-D "$LDAP_BIND_DN" \
-w "$LDAP_BIND_PW" \
-b "cn=role-$role,$ROLES_DN" \
member | grep member: | awk '{print $2}' | while read dn
do

user_roles["$dn"]+="$role "

done

done


for dn in "${!user_roles[@]}"; do

roles_list=${user_roles[$dn]}

primary=$(echo $roles_list | awk '{print $1}')
alternate=$(echo $roles_list | cut -d' ' -f2-)

echo "dn: $dn" >> $TMP
echo "changetype: modify" >> $TMP

echo "replace: petraAffiliation" >> $TMP
echo "petraAffiliation: $primary" >> $TMP
echo "-" >> $TMP

echo "replace: petraAlternateAffiliation" >> $TMP

for r in $alternate; do
echo "petraAlternateAffiliation: $r" >> $TMP
done

echo "" >> $TMP

done


ldapmodify -x \
-H "$LDAP_URI" \
-D "$LDAP_BIND_DN" \
-w "$LDAP_BIND_PW" \
-f $TMP