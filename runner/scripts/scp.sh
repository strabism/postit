#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Paramètres transmis par ctm.sh
# ============================================================

SERVER="${1:-}"
REP_CIBLE="${2:-}"

if [[ -z "$SERVER" || -z "$REP_CIBLE" ]]; then
    echo "ERREUR : SERVER ou REP_CIBLE manquant." >&2
    exit 1
fi

# ============================================================
# Configuration
# ============================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BASE_DIR/config/servers.conf"

# ============================================================
# Paramètres métier
# ============================================================

REMOTE_FILE="/opt/controlm/export/mon_fichier.csv"

# ============================================================
# Vérification du répertoire cible
# ============================================================

mkdir -p "$REP_CIBLE"

# ============================================================
# Récupération SCP
# ============================================================

echo "Récupération depuis $SERVER"
echo "Fichier distant : $REMOTE_FILE"
echo "Destination locale : $REP_CIBLE"

scp "${SSH_OPTS[@]}" \
    "${SSH_USER}@${SERVER}:${REMOTE_FILE}" \
    "$REP_CIBLE/"

echo "Récupération terminée depuis $SERVER"

exit 0
