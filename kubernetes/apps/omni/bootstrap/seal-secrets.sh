#!/usr/bin/env bash
# Reproducibly generate + seal the three Omni deploy secrets, so this whole platform
# can be stood up again from code. Produces kubernetes/apps/omni/sealed-secret.yaml:
#   - omni-etcd-key  (omni.asc)        GPG private key that encrypts Omni's etcd
#   - omni-config    (omni-config.yaml) Omni's OIDC clientSecret (no CLI flag exists for it)
#   - omni-dex-config(config.yaml)      the Dex OIDC provider config (static admin user)
# The OIDC client secret is SHARED between omni-config and the Dex staticClient (they must match).
#
# ⚠️  Regenerating these creates a NEW etcd key and a NEW admin password. Run it for a FRESH
#     deploy only. Against a LIVE Omni it would make the existing etcd undecryptable — so by
#     default it refuses to overwrite an existing sealed-secret.yaml (pass --force to override).
#
# Requires: gpg, openssl, kubeseal, kubectl (ctx with access to the target cluster's
#           sealed-secrets controller), and htpasswd (apache2-utils / httpd) for the bcrypt hash.
#
# Usage:
#   ./seal-secrets.sh                 # generate into ./_staging, print the admin password
#   ./seal-secrets.sh --force         # also overwrite ../sealed-secret.yaml (fresh deploy)
set -euo pipefail
cd "$(dirname "$0")"

# ---- config (override via env) ----
OMNI_HOST="${OMNI_HOST:-omni.qualityspace.com}"
AUTH_HOST="${AUTH_HOST:-auth.qualityspace.com}"
OMNI_PORT="${OMNI_PORT:-8443}"
AUTH_PORT="${AUTH_PORT:-5556}"
ADMIN_EMAIL="${ADMIN_EMAIL:-vietcgi@gmail.com}"
NS="${NS:-omni-system}"
SEALED_CONTROLLER_NAME="${SEALED_CONTROLLER_NAME:-sealed-secrets}"
SEALED_CONTROLLER_NS="${SEALED_CONTROLLER_NS:-sealed-secrets}"
OUT="${OUT:-$PWD/_staging}"     # staging dir (gitignored); the sealed yaml is emitted to ../
FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1

for t in gpg openssl kubeseal kubectl htpasswd; do
  command -v "$t" >/dev/null || { echo "missing required tool: $t"; exit 1; }
done
mkdir -p "$OUT"; chmod 700 "$OUT"

# Reuse already-staged material so "stage -> review -> --force" publishes EXACTLY what you
# reviewed (not freshly regenerated secrets). Delete $OUT to force a clean regeneration.
REUSE=0
if [ -f "$OUT/omni.asc" ] && [ -f "$OUT/omni-config.yaml" ] && [ -f "$OUT/dex-config.yaml" ]; then
  REUSE=1
  echo "reusing existing staged material in $OUT (value-stable; rm -rf $OUT to regenerate)"
fi

if [ "$REUSE" -eq 0 ]; then
  # ---- 1. shared secrets ----
  OIDC_CLIENT_SECRET="$(openssl rand -hex 32)"
  ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-28)}"
  # dex wants a bcrypt hash; htpasswd -B emits $2y$, which dex accepts
  BCRYPT="$(htpasswd -bnBC 10 '' "$ADMIN_PASSWORD" | tr -d ':\n')"
  ADMIN_USERID="$(uuidgen | tr 'a-z' 'A-Z')"

  # ---- 2. GPG etcd-encryption key -> omni.asc ----
  G="$(mktemp -d /tmp/ogpg.XXXXXX)"; export GNUPGHOME="$G"; chmod 700 "$G"
  gpg --batch --pinentry-mode loopback --passphrase '' \
      --quick-generate-key "Omni etcd <$ADMIN_EMAIL>" rsa4096 cert never >/dev/null 2>&1
  FP="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
  gpg --batch --pinentry-mode loopback --passphrase '' \
      --export-secret-keys --armor "$FP" > "$OUT/omni.asc"
  rm -rf "$G"; echo "generated etcd key -> $OUT/omni.asc"

  # ---- 3. render the two config files ----
  cat > "$OUT/omni-config.yaml" <<EOF
auth:
  oidc:
    clientSecret: $OIDC_CLIENT_SECRET
EOF

  cat > "$OUT/dex-config.yaml" <<EOF
issuer: https://$AUTH_HOST:$AUTH_PORT
storage:
  type: memory
web:
  https: 0.0.0.0:$AUTH_PORT
  tlsCert: /tls/tls.crt
  tlsKey: /tls/tls.key
enablePasswordDB: true
oauth2:
  skipApprovalScreen: true
staticClients:
  - id: omni
    name: Omni
    secret: $OIDC_CLIENT_SECRET
    redirectURIs:
      - "https://$OMNI_HOST:$OMNI_PORT/oidc/consume"
staticPasswords:
  - email: "$ADMIN_EMAIL"
    username: admin
    userID: "$ADMIN_USERID"
    hash: $BCRYPT
EOF
fi

# ---- 4. seal all three into one sealed-secret.yaml (strict scope, ns-pinned) ----
# Seal against the live controller (default) or, if SEALED_CERT points at the controller's
# public cert, offline with --cert (lets you reseal from a fresh checkout without kube API access).
seal() { # $1 secret name, $2 file key, $3 path
  local ks=(kubeseal --format yaml)
  if [ -n "${SEALED_CERT:-}" ]; then ks+=(--cert "$SEALED_CERT")
  else ks+=(--controller-name "$SEALED_CONTROLLER_NAME" --controller-namespace "$SEALED_CONTROLLER_NS"); fi
  kubectl create secret generic "$1" -n "$NS" --dry-run=client -o yaml \
    --from-file="$2=$3" | "${ks[@]}"
}
{
  seal omni-etcd-key   omni.asc          "$OUT/omni.asc"
  echo "---"
  seal omni-config     omni-config.yaml  "$OUT/omni-config.yaml"
  echo "---"
  seal omni-dex-config config.yaml       "$OUT/dex-config.yaml"
} > "$OUT/sealed-secret.yaml"

echo
echo "sealed -> $OUT/sealed-secret.yaml"
if [ "$REUSE" -eq 0 ]; then
  echo "ADMIN PASSWORD (save to your password manager now; not stored elsewhere):"
  echo "    $ADMIN_PASSWORD"
else
  echo "(reused staged material — admin password was printed on the run that generated it)"
fi
echo

if [ "$FORCE" -eq 1 ]; then
  cp "$OUT/sealed-secret.yaml" ../sealed-secret.yaml
  echo "overwrote ../sealed-secret.yaml — commit it; Flux will apply, then restart omni-0 + dex."
  echo "If this is NOT a fresh cluster, the new etcd key makes existing Omni data undecryptable."
else
  echo "staged only. Review $OUT/sealed-secret.yaml, then re-run with --force to overwrite the"
  echo "committed ../sealed-secret.yaml (fresh deploy only)."
fi
# never commit the plaintext staging dir
