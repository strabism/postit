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
# Traitement
# ============================================================

echo "Lancement du traitement sur $SERVER"
echo "Répertoire cible : $REP_CIBLE"

REMOTE_SCRIPT="/opt/controlm/scripts/mon_traitement.sh"

ssh "${SSH_OPTS[@]}" \
    "${SSH_USER}@${SERVER}" \
    "bash $REMOTE_SCRIPT"

echo "Traitement terminé sur $SERVER"

exit 0
