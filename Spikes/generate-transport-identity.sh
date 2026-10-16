#!/bin/sh
set -eu
umask 077

directory=$1
host=$2
# Fail rather than overwrite an existing identity or fixture.
mkdir "$directory"
openssl rand -hex 32 > "$directory/password.txt"
openssl req -new -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -nodes -days 1 -subj "/CN=Pi Remote Transport Spike" \
  -addext "subjectAltName=IP:$host,IP:127.0.0.1" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign" \
  -addext "extendedKeyUsage=serverAuth" \
  -keyout "$directory/key.pem" -out "$directory/certificate.pem"
openssl x509 -in "$directory/certificate.pem" -outform DER -out "$directory/certificate.der"
# Use the PKCS#12 algorithms supported by Apple's importer; all files remain private and temporary.
openssl pkcs12 -export -inkey "$directory/key.pem" -in "$directory/certificate.pem" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout "file:$directory/password.txt" -out "$directory/identity.p12"
openssl req -new -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -nodes -days 1 -subj "/CN=Untrusted Test Identity" \
  -addext "subjectAltName=IP:$host,IP:127.0.0.1" \
  -keyout "$directory/rejected-key.pem" -out "$directory/rejected.pem"
openssl x509 -in "$directory/rejected.pem" -outform DER -out "$directory/rejected.der"
