#!/usr/bin/env bash

set -u

# ------------------------------------------------------------------
# Serveur transmis par le moteur principal
# ------------------------------------------------------------------

SERVER="${1:-}"

if [[ -z "$SERVER" ]]; then
    echo "Erreur : aucun serveur transmis."
    exit 1
fi

# ------------------------------------------------------------------
# Répertoires et configuration
# ------------------------------------------------------------------

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$BASE_DIR/config/servers.conf"

DEST_DIR="$BASE_DIR/output/$SERVER"

mkdir -p "$DEST_DIR"

# ------------------------------------------------------------------
# Récupération des fichiers
# ------------------------------------------------------------------

echo "Récupération des fichiers depuis $SERVER"

scp -r \
    "${SSH_OPTS[@]}" \
    "$SSH_USER@$SERVER:/tmp/yolo/." \
    "$DEST_DIR/"

rc=$?

if (( rc != 0 )); then
    echo "Erreur SCP depuis $SERVER (rc=$rc)"
    exit "$rc"
fi

echo "Récupération terminée : $DEST_DIR"

exit 0
