#!/usr/bin/env bash

LDAP_URI="${LDAP_URI}"
LDAP_BIND_DN="${LDAP_BIND_DN}"
LDAP_BIND_PW="${LDAP_BIND_PW}"

BASE="ou=people,dc=petra,dc=ac,dc=id"

TMP=/tmp/petra_guard.ldif
> $TMP

ldapsearch -LLL -x \
-H "$LDAP_URI" \
-D "$LDAP_BIND_DN" \
-w "$LDAP_BIND_PW" \
-b "$BASE" \
"(petraAffiliation=*)" \
dn petraAffiliation petraAlternateAffiliation |

awk '
/^dn:/ {dn=$2}
/petraAffiliation:/ {primary=$2}
/petraAlternateAffiliation:/ {
if($2==primary){
print "dn: "dn
print "changetype: modify"
print "delete: petraAlternateAffiliation"
print "petraAlternateAffiliation: "$2
print ""
}
}
' >> $TMP

if [ -s "$TMP" ]; then

ldapmodify -x \
-H "$LDAP_URI" \
-D "$LDAP_BIND_DN" \
-w "$LDAP_BIND_PW" \
-f "$TMP"

fi