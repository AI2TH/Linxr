#!/usr/bin/env bash
# Generate an upload keystore for Google Play Store signing (Linxr).
# Run once. Keep the keystore and key.properties SECRET — never commit them.
#
# Usage: ./scripts/gen_keystore.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KEYSTORE="$PROJECT_ROOT/android/app/upload-keystore.jks"
KEY_PROPERTIES="$PROJECT_ROOT/android/key.properties"

if [ -f "$KEYSTORE" ]; then
    echo "Keystore already exists at $KEYSTORE — delete it first to regenerate."
    exit 1
fi

read -p "Key alias [upload]: " ALIAS
ALIAS="${ALIAS:-upload}"
read -s -p "Store password: " STORE_PASS; echo
read -s -p "Key password (leave blank to use store password): " KEY_PASS; echo
KEY_PASS="${KEY_PASS:-$STORE_PASS}"
read -p "Your name or organization (e.g. AI2TH): " DNAME

keytool -genkey -v \
    -keystore "$KEYSTORE" \
    -storetype JKS \
    -alias "$ALIAS" \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -storepass "$STORE_PASS" \
    -keypass "$KEY_PASS" \
    -dname "CN=$DNAME, OU=Android, O=$DNAME, L=Unknown, ST=Unknown, C=US"

cat > "$KEY_PROPERTIES" <<EOF
storePassword=$STORE_PASS
keyPassword=$KEY_PASS
keyAlias=$ALIAS
storeFile=upload-keystore.jks
EOF

echo ""
echo "Keystore : $KEYSTORE"
echo "Properties: $KEY_PROPERTIES"
echo "KEEP THESE SECRET — do not commit to git."
