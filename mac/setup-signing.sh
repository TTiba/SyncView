#!/bin/zsh
# Cria (uma vez) um certificado local de assinatura "SyncView Local Signing"
# num keychain próprio. Com uma identidade fixa, o macOS mantém as permissões
# (Gravação de Tela, Acessibilidade) mesmo depois de recompilar o app.
set -euo pipefail
KC="$HOME/Library/Keychains/syncview-signing.keychain-db"
PASS="syncview-local"
NAME="SyncView Local Signing"

if [[ -f "$KC" ]] && security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout pass:$PASS 2>/dev/null

[[ -f "$KC" ]] || security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"            # sem bloqueio automático
security unlock-keychain -p "$PASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null
echo "Certificado '$NAME' criado em $KC"
