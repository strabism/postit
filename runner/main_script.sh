
#!/usr/bin/env bash

set -uo pipefail

# ============================================================
# Initialisation
# ============================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="$BASE_DIR/config/servers.conf"
SCRIPTS_DIR="$BASE_DIR/scripts"
OUTPUT_DIR="$BASE_DIR/output"
LOG_DIR="$BASE_DIR/logs"
LOCK_DIR="$BASE_DIR/locks"

LOG_FILE="$LOG_DIR/logs_ctm.log"
LOG_LOCK="$LOCK_DIR/logs.lock"

RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"

mkdir -p "$LOG_DIR" "$LOCK_DIR"

# ============================================================
# Chargement configuration
# ============================================================

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Configuration introuvable : $CONFIG_FILE" >&2
    exit 1
fi

source "$CONFIG_FILE"

# Valeurs par défaut si non définies
ACTIVE_PORT="${ACTIVE_PORT:-7005}"
NC_TIMEOUT="${NC_TIMEOUT:-3}"
MAX_LOG_SIZE="${MAX_LOG_SIZE:-10485760}"

# ============================================================
# Journalisation centrale
# ============================================================

log() {
    local level="$1"
    local event="$2"
    shift 2

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    (
        flock -x 200 || exit 1

        if [[ -f "$LOG_FILE" ]]; then
            local size
            size="$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)"

            if (( size >= MAX_LOG_SIZE )); then
                local archive
                archive="$LOG_DIR/logs_ctm_$(date '+%Y%m%d_%H%M%S_%N')_$$.log"

                if mv "$LOG_FILE" "$archive"; then
                    gzip "$archive"
                fi
            fi
        fi

        {
            printf '[%s] [%s] [%s] run_id=%s' \
                "$timestamp" "$level" "$event" "$RUN_ID"

            for field in "$@"; do
                printf ' %s' "$field"
            done

            printf '\n'
        } >> "$LOG_FILE"

    ) 200>"$LOG_LOCK"
}

# ============================================================
# Aide
# ============================================================

usage() {
    cat <<EOF
Utilisation :

  $0 -s <serveur|ALL|BACKUP> -f <fonction> [-w <repertoire>] [--clean]

Options :

  -s, --server      Serveur, alias de paire, ALL ou BACKUP
  -f, --function    Script métier à exécuter dans scripts/
  -w, --workdir     Sous-répertoire de output/
  --clean           Purge le contenu du répertoire cible avant exécution
  -h, --help        Affiche cette aide

Exemples :

  $0 -s ALL -f script_classique
  $0 -s CTMP01 -f script_scp -w extraction
  $0 -s ALL -f script_scp -w extraction --clean

EOF
}

# ============================================================
# Lecture des paramètres
# ============================================================

SERVER_TARGET=""
FUNCTION=""
WORK_SUBDIR=""
WORKDIR_SPECIFIED=0
CLEAN=0

while (($# > 0)); do
    case "$1" in
        -s|--server)
            [[ $# -ge 2 ]] || { usage; exit 1; }
            SERVER_TARGET="$2"
            shift 2
            ;;
        -f|--function)
            [[ $# -ge 2 ]] || { usage; exit 1; }
            FUNCTION="$2"
            shift 2
            ;;
        -w|--workdir)
            [[ $# -ge 2 ]] || { usage; exit 1; }
            WORK_SUBDIR="$2"
            WORKDIR_SPECIFIED=1
            shift 2
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Option inconnue : $1" >&2
            usage
            exit 1
            ;;
    esac
done

# Sans serveur : aucune action
if [[ -z "$SERVER_TARGET" ]]; then
    exit 0
fi

# --clean nécessite impérativement -w
if (( CLEAN == 1 && WORKDIR_SPECIFIED == 0 )); then
    echo "ERREUR : --clean nécessite l'option -w." >&2
    exit 1
fi

if [[ -z "$FUNCTION" ]]; then
    echo "ERREUR : fonction manquante (-f)." >&2
    usage
    exit 1
fi

# ============================================================
# Vérification du script métier
# ============================================================

SCRIPT="$SCRIPTS_DIR/${FUNCTION}.sh"

if [[ ! -f "$SCRIPT" ]]; then
    log ERROR SCRIPT_NOT_FOUND "function=$FUNCTION"
    echo "Script métier introuvable : $SCRIPT" >&2
    exit 1
fi

# ============================================================
# Détermination de REP_CIBLE
# ============================================================

if (( WORKDIR_SPECIFIED == 1 )); then

    # Refus des chemins absolus, vides et des traversées de répertoire
    if [[ -z "$WORK_SUBDIR" || "$WORK_SUBDIR" == /* ||
          "$WORK_SUBDIR" == "." || "$WORK_SUBDIR" == ".." ||
          "/$WORK_SUBDIR/" == */../* ]]; then
        echo "ERREUR : répertoire cible invalide." >&2
        exit 1
    fi

    REP_CIBLE="$OUTPUT_DIR/$WORK_SUBDIR"
else
    REP_CIBLE="$OUTPUT_DIR"
fi

# Création du répertoire cible
mkdir -p "$REP_CIBLE" || {
    log ERROR OUTPUT_DIRECTORY_ERROR "path=$REP_CIBLE"
    exit 1
}

# Refus de nettoyer un lien symbolique
if (( CLEAN == 1 )) && [[ -L "$REP_CIBLE" ]]; then
    log ERROR CLEAN_REFUSED "reason=symlink" "path=$REP_CIBLE"
    echo "ERREUR : le répertoire cible est un lien symbolique." >&2
    exit 1
fi

# ============================================================
# Nettoyage éventuel : une seule fois avant les traitements
# ============================================================

if (( CLEAN == 1 )); then

    log INFO CLEAN_START "path=$REP_CIBLE"

    find "$REP_CIBLE" -mindepth 1 -maxdepth 1 \
        -exec rm -rf -- {} + || {
            log ERROR CLEAN_FAILED "path=$REP_CIBLE"
            exit 1
        }

    log INFO CLEAN_END "path=$REP_CIBLE"
fi

# ============================================================
# Test du port actif Control-M
# ============================================================

is_active() {
    local host="$1"

    nc -z -w "$NC_TIMEOUT" "$host" "$ACTIVE_PORT" \
        >/dev/null 2>&1
}

# ============================================================
# Résolution d'une paire de production
# ============================================================

resolve_pair() {
    local pair_name="$1"
    local host_a="$2"
    local host_b="$3"
    local mode="$4"

    local active_a=0
    local active_b=0

    is_active "$host_a" && active_a=1
    is_active "$host_b" && active_b=1

    if (( active_a == 1 && active_b == 1 )); then
        log ERROR PAIR_INCONSISTENT \
            "pair=$pair_name" "host_a=$host_a" "host_b=$host_b"
        return 1
    fi

    if (( active_a == 0 && active_b == 0 )); then
        log WARN PAIR_UNAVAILABLE \
            "pair=$pair_name" "host_a=$host_a" "host_b=$host_b"
        return 1
    fi

    local selected

    if [[ "$mode" == "ACTIVE" ]]; then
        if (( active_a == 1 )); then
            selected="$host_a"
        else
            selected="$host_b"
        fi
    else
        if (( active_a == 0 )); then
            selected="$host_a"
        else
            selected="$host_b"
        fi
    fi

    echo "$selected"
}

# ============================================================
# Recherche d'un alias de paire
# ============================================================

find_pair() {
    local requested="$1"

    local pair alias host_a host_b

    for pair in "${PROD_PAIRS[@]}"; do
        IFS=: read -r alias host_a host_b <<< "$pair"

        if [[ "$requested" == "$alias" ]]; then
            echo "$host_a:$host_b"
            return 0
        fi
    done

    return 1
}

# ============================================================
# Construction de la liste des serveurs
# ============================================================

SERVERS=()

add_server() {
    local host="$1"

    [[ -n "$host" ]] || return 0

    local existing
    for existing in "${SERVERS[@]}"; do
        [[ "$existing" == "$host" ]] && return 0
    done

    SERVERS+=("$host")
}

select_all_active() {
    local pair alias host_a host_b selected

    for pair in "${PROD_PAIRS[@]}"; do
        IFS=: read -r alias host_a host_b <<< "$pair"

        selected="$(resolve_pair "$alias" "$host_a" "$host_b" ACTIVE)" || continue
        add_server "$selected"
    done

    local host
    for host in "${PREPROD_SERVERS[@]}"; do
        add_server "$host"
    done
}

select_all_backup() {
    local pair alias host_a host_b selected

    for pair in "${PROD_PAIRS[@]}"; do
        IFS=: read -r alias host_a host_b <<< "$pair"

        selected="$(resolve_pair "$alias" "$host_a" "$host_b" BACKUP)" || continue
        add_server "$selected"
    done
}

select_requested_server() {
    local pair_data alias host_a host_b selected

    # Alias de paire : sélection du serveur actif
    if pair_data="$(find_pair "$SERVER_TARGET")"; then
        IFS=: read -r host_a host_b <<< "$pair_data"

        selected="$(resolve_pair "$SERVER_TARGET" "$host_a" "$host_b" ACTIVE)" || return 0
        add_server "$selected"
        return 0
    fi

    # Nom d'hôte direct : pas de contrôle actif/passif
    add_server "$SERVER_TARGET"
}

case "$SERVER_TARGET" in
    ALL)
        select_all_active
        ;;
    BACKUP)
        select_all_backup
        ;;
    *)
        select_requested_server
        ;;
esac

if ((${#SERVERS[@]} == 0)); then
    log WARN NO_SERVER_SELECTED "target=$SERVER_TARGET"
    exit 0
fi

log INFO SELECTION_COMPLETE \
    "target=$SERVER_TARGET" \
    "function=$FUNCTION" \
    "count=${#SERVERS[@]}" \
    "rep_cible=$REP_CIBLE"

# ============================================================
# Exécution d'un script métier
# ============================================================

run() (
    local host="$1"
    local lock_file="$LOCK_DIR/${FUNCTION}_${host}.lock"

    local start_time
    start_time="$(date +%s)"

    # Verrou par fonction et serveur
    exec 200>"$lock_file"

    if ! flock -n 200; then
        log WARN LOCK_BUSY "function=$FUNCTION" "server=$host"
        exit 75
    fi

    log INFO EXEC_START \
        "function=$FUNCTION" \
        "server=$host" \
        "rep_cible=$REP_CIBLE"

    bash "$SCRIPT" "$host" "$REP_CIBLE"
    local rc=$?

    local end_time
    end_time="$(date +%s)"

    local duration=$((end_time - start_time))

    if (( rc == 0 )); then
        log INFO EXEC_END \
            "function=$FUNCTION" \
            "server=$host" \
            "rc=0" \
            "duration=${duration}s"
        exit 0
    else
        log ERROR EXEC_FAILED \
            "function=$FUNCTION" \
            "server=$host" \
            "rc=$rc" \
            "duration=${duration}s"
        exit 1
    fi
)

# ============================================================
# Lancement parallèle
# ============================================================

PIDS=()
HOSTS=()

for host in "${SERVERS[@]}"; do
    run "$host" &
    PIDS+=("$!")
    HOSTS+=("$host")
done

# ============================================================
# Attente et bilan
# ============================================================

SUCCESS=0
FAILED=0
SKIPPED=0

for i in "${!PIDS[@]}"; do

    if wait "${PIDS[$i]}"; then
        ((SUCCESS+=1))
    else
        rc=$?

        if (( rc == 75 )); then
            ((SKIPPED+=1))
        else
            ((FAILED+=1))
        fi
    fi

done

log INFO RUN_END \
    "function=$FUNCTION" \
    "success=$SUCCESS" \
    "failed=$FAILED" \
    "skipped=$SKIPPED"

echo "Traitement terminé."
echo "Réussites : $SUCCESS"
echo "Échecs    : $FAILED"
echo "Ignorés   : $SKIPPED"

(( FAILED == 0 ))
