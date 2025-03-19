#!/bin/bash

set -e  # Arrête le script en cas d'erreur
set -o pipefail  # Échoue si une commande dans un pipe échoue

# Variables
TAR_FILE="archive.tar.gz"
TMP_DIR=$(mktemp -d)
DRYRUN=true

# Gestion du trap pour nettoyer les fichiers temporaires
cleanup() {
    echo "[INFO] Nettoyage des fichiers temporaires..."
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Vérifier si l'argument --prod est présent
if [[ "$1" == "--prod" ]]; then
    DRYRUN=false
fi

# Extraire temporairement le tar.gz
echo "[INFO] Extraction de $TAR_FILE dans $TMP_DIR..."
tar -xzf "$TAR_FILE" -C "$TMP_DIR"

# Parcourir les 5 répertoires extraits
for dir in "$TMP_DIR"/*; do
    if [[ -d "$dir" ]]; then
        echo "[INFO] Analyse du répertoire: $dir"

        # Exemple d'analyse d'un fichier spécifique
        FILE="$dir/config.txt"
        if [[ -f "$FILE" ]]; then
            ACTION_NEEDED=false

            # Vérifier si l'action est nécessaire (ex: chercher une ligne spécifique)
            if ! grep -q "activation=ok" "$FILE"; then
                echo "[INFO] L'activation n'est pas encore faite pour $FILE"
                ACTION_NEEDED=true
            else
                echo "[INFO] Déjà activé, aucune action requise."
            fi

            # Exécuter l'action si nécessaire et en mode prod
            if $ACTION_NEEDED; then
                if $DRYRUN; then
                    echo "[DRYRUN] Activation de $FILE (simulation)"
                else
                    echo "[PROD] Activation réelle de $FILE"
                    echo "activation=ok" >> "$FILE"  # Exemple d'action
                fi
            fi
        else
            echo "[WARN] Fichier de configuration non trouvé dans $dir"
        fi
    fi
done

echo "[INFO] Script terminé."
