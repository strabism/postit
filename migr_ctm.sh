#!/bin/bash

set -euo pipefail  # Arrête le script en cas d'erreur, interdit les variables non définies et échoue si une commande dans un pipe échoue

# Variables
TMP_DIR="${PWD}/tmp"
DRYRUN=true
LOG_FILE="log.log"
CAL_DIR_BASE="${PWD}/cal"
LIBMEMSYM_DIR="/logiciels/controlm/srv_9.0.00/libmemsym"

# Logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $1"
}

exec > >(tee -a "$LOG_FILE") 2>&1

# Gestion du trap pour nettoyer les fichiers temporaires
cleanup() {
    log "Nettoyage des fichiers temporaires..."
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Initialisation des fichiers
> STRANGERCOND.txt
> SHOUT.txt

# Vérifier si l'argument --prod est présent
if [[ "${1:-}" == "--prod" ]]; then
    DRYRUN=false
fi

mkdir -p "$TMP_DIR"

log "Extraction des archives référentielles..."
for tar_file in "$PWD"/*.tar; do
    [[ -f "$tar_file" ]] || continue
    extract_dir="$TMP_DIR/$(basename "$tar_file" .tar)"
    if [[ ! -d "$extract_dir" ]]; then
        log "Extraction de $tar_file dans $extract_dir..."
        if $DRYRUN; then
            log "[DRY RUN] tar xf $tar_file -C $TMP_DIR"
        else
            if tar xf "$tar_file" -C "$TMP_DIR"; then
                log "Extraction OK"
            else
                log "[ERROR] Échec de l'extraction de $tar_file"
                exit 1
            fi
        fi
    else
        log "L'archive $tar_file est déjà extraite."
    fi
done

for dossier in "$TMP_DIR"/*; do
    [[ -d "$dossier" ]] || continue
    echo "------------------------------"
    index_file="$dossier/.index.toc"
    ref_name=$(awk -F= '/EXP_TABLE/ {print $2}' "$index_file")
    log "Vérification si le référentiel $ref_name existe..."

    if $DRYRUN; then
        log "[DRY RUN] /logiciels/controlm/srv_9.0.00/ctm_cli/9.0.21.300/ctm deploy jobs::get -s \"ctm=*&folder=${ref_name}\""
    elif ! /logiciels/controlm/srv_9.0.00/ctm_cli/9.0.21.300/ctm deploy jobs::get -s "ctm=*&folder=${ref_name}" &>/dev/null; then
        log "Le référentiel $ref_name n'existe pas, ajout en cours..."
        schedtable_utf8="$dossier/schedtable_utf8.xml"
        if iconv -f iso-8859-1 -t utf-8 "$dossier/schedtable.xml" -o "$schedtable_utf8"; then
            if $DRYRUN; then
                log "[DRY RUN] sed -i '1s/ISO-8859-1/UTF-8/' \"$schedtable_utf8\""
                log "[DRY RUN] sed -i 's/DATACENTER=\"[^\"]*\"/DATACENTER=\"POCISIM2\"/' \"$schedtable_utf8\""
                log "[DRY RUN] sed -i 's/VERSION=\"[^\"]*\"/VERSION=\"921\"/' \"$schedtable_utf8\""
            else
                sed -i '1s/ISO-8859-1/UTF-8/' "$schedtable_utf8"
                sed -i 's/DATACENTER="[^"]*"/DATACENTER="POCISIM2"/' "$schedtable_utf8"
                sed -i 's/VERSION="[^"]*"/VERSION="921"/' "$schedtable_utf8"
            fi
        else
            log "[ERROR] Échec de la conversion du fichier XML"
            exit 1
        fi
    else
        log "Le référentiel $ref_name existe déjà."
    fi

    log "Vérification des calendriers..."
    exp_cal=$(awk -F= '/EXP_CAL/ {print $2}' "$index_file" || echo "")
    if [[ -n "$exp_cal" ]]; then
        IFS=':' read -ra calendriers <<< "$exp_cal"
        for calendrier in "${calendriers[@]}"; do
            log "Vérification du calendrier $calendrier..."
            if $DRYRUN; then
                log "[DRY RUN] /logiciels/controlm/srv_9.0.00/ctm_cli/9.0.21.300/ctm deploy calendars::get -s \"name=$calendrier&server=*\""
            elif ! /logiciels/controlm/srv_9.0.00/ctm_cli/9.0.21.300/ctm deploy calendars::get -s "name=$calendrier&server=*" &>/dev/null; then
                if [[ -f "${CAL_DIR_BASE}/${calendrier}.json" ]]; then
                    if $DRYRUN; then
                        log "[DRY RUN] sed -i 's/\"Server\":.*/\"Server\": \"POCISIM2\",/' \"${CAL_DIR_BASE}/${calendrier}.json\""
                    else
                        sed -i 's/"Server":.*/"Server": "POCISIM2",/' "${CAL_DIR_BASE}/${calendrier}.json"
                    fi
                    log "Import du calendrier $calendrier terminé."
                else
                    log "[WARN] Pas de source pour le calendrier $calendrier."
                fi
            else
                log "Le calendrier $calendrier existe déjà."
            fi
        done
    else
        log "Aucun calendrier défini dans EXP_CAL."
    fi

    log "Vérification des fichiers libmemsym..."
    exp_lib=$(awk -F= '/EXP_LIB/ {print $2}' "$index_file" || echo "")
    if [[ -n "$exp_lib" ]]; then
        IFS=':' read -ra libs <<< "$exp_lib"
        for lib in "${libs[@]}"; do
            log "Vérification de l'existence de la libmemsym : ${lib}"
            if [[ ! -f "$LIBMEMSYM_DIR/$lib" ]]; then
                if $DRYRUN; then
                    log "[DRY RUN] cp $dossier/lib/${lib}.lib $LIBMEMSYM_DIR/$lib"
                    log "[DRY RUN] chown controlm:controlm $LIBMEMSYM_DIR/$lib"
                else
                    cp "$dossier/lib/${lib}.lib" "$LIBMEMSYM_DIR/$lib"
                    chown controlm:controlm "$LIBMEMSYM_DIR/$lib"
                    log "Ajout de $lib terminé."
                fi
            else
                log "Le fichier libmemsym ${lib} existe déjà."
            fi
        done
    else
        log "Aucun fichier libmemsym défini."
    fi

    log "[FIN] Script terminé."
done
