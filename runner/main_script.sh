#!/usr/bin/env bash

set -u

# ------------------------------------------------------------------
# Répertoires
# ------------------------------------------------------------------

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="$BASE_DIR/config/servers.conf"
SCRIPTS_DIR="$BASE_DIR/scripts"
LOG_DIR="$BASE_DIR/logs"
LOCK_DIR="$BASE_DIR/locks"

LOG_FILE="$LOG_DIR/logs_ctm.log"
LOG_LOCK="$LOCK_DIR/logs.lock"

mkdir -p "$LOG_DIR" "$LOCK_DIR"

# ------------------------------------------------------------------
# Chargement de la configuration
# ------------------------------------------------------------------

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Configuration introuvable : $CONFIG_FILE" >&2
    exit 1
fi

source "$CONFIG_FILE"

# ------------------------------------------------------------------
# Identifiant unique du lancement
#
# Généré une seule fois et conservé pour tous les traitements.
# ------------------------------------------------------------------

RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"

# ------------------------------------------------------------------
# Gestion des logs
# ------------------------------------------------------------------

log() {
    local level="$1"
    local event="$2"
    shift 2

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    (
        flock -x 200

        # Rotation si le fichier dépasse la taille maximale
        if [[ -f "$LOG_FILE" ]]; then
            local size
            size="$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)"

            if (( size >= MAX_LOG_SIZE )); then
                local archive
                archive="$LOG_DIR/logs_ctm_$(date '+%Y%m%d_%H%M%S')_${$}.log"

                mv "$LOG_FILE" "$archive"
                gzip "$archive"
            fi
        fi

        printf '[%s] [%s] [%s] run_id=%s' \
            "$timestamp" "$level" "$event" "$RUN_ID" >> "$LOG_FILE"

        for field in "$@"; do
            printf ' %s' "$field" >> "$LOG_FILE"
        done

        printf '\n' >> "$LOG_FILE"

    ) 200>"$LOG_LOCK"
}

# ------------------------------------------------------------------
# Vérification du port Control-M
#
# Retourne :
#   0 : serveur actif
#   1 : serveur ne répond pas
# ------------------------------------------------------------------

is_active() {
    local host="$1"
    local rc

    nc -z -w "$NC_TIMEOUT" "$host" "$ACTIVE_PORT" \
        >/dev/null 2>&1
    rc=$?

    if (( rc == 0 )); then
        log INFO NC_CHECK \
            "server=$host" \
            "port=$ACTIVE_PORT" \
            "rc=0" \
            "status=RESPONDS"
        return 0
    else
        log INFO NC_CHECK \
            "server=$host" \
            "port=$ACTIVE_PORT" \
            "rc=$rc" \
            "status=NO_RESPONSE"
        return 1
    fi
}

# ------------------------------------------------------------------
# Sélection d'un serveur dans une paire
#
# mode ACTIVE  : retourne le serveur actif
# mode BACKUP  : retourne le serveur passif
#
# Si les deux serveurs sont indisponibles :
# aucun serveur n'est retourné.
# ------------------------------------------------------------------

select_server() {
    local server_a="$1"
    local server_b="$2"
    local mode="$3"

    local active_a=0
    local active_b=0

    is_active "$server_a" && active_a=1
    is_active "$server_b" && active_b=1

    if (( active_a == 1 && active_b == 1 )); then
        log ERROR PAIR_INCONSISTENT \
            "server_a=$server_a" \
            "server_b=$server_b"
        return 1
    fi

    if (( active_a == 1 )); then
        if [[ "$mode" == "ACTIVE" ]]; then
            echo "$server_a"
        else
            echo "$server_b"
        fi
        return 0
    fi

    if (( active_b == 1 )); then
        if [[ "$mode" == "ACTIVE" ]]; then
            echo "$server_b"
        else
            echo "$server_a"
        fi
        return 0
    fi

    log WARN SERVER_UNAVAILABLE \
        "servers=$server_a,$server_b"

    return 1
}

# ------------------------------------------------------------------
# Exécution du script métier sur l'hôte d'outillage
#
# Le serveur Control-M sélectionné est transmis en argument $1.
# Un verrou est créé par fonction et par serveur.
# ------------------------------------------------------------------

run() {
    local host="$1"

    (
        local lock_file
        local start_time
        local end_time
        local duration
        local rc

        lock_file="$LOCK_DIR/${FUNCTION}_${host}.lock"

        # Verrouillage non bloquant
        exec 200>"$lock_file"

        if ! flock -n 200; then
            log WARN LOCK_BUSY \
                "server=$host" \
                "function=$FUNCTION"

            exit 2
        fi

        log INFO LOCK_ACQUIRED \
            "server=$host" \
            "function=$FUNCTION"

        start_time="$(date +%s)"

        log INFO EXEC_START \
            "server=$host" \
            "function=$FUNCTION" \
            "pid=$BASHPID"

        # Exécution locale du script métier
        bash "$SCRIPT" "$host"
        rc=$?

        end_time="$(date +%s)"
        duration=$((end_time - start_time))

        if (( rc == 0 )); then
            log INFO EXEC_END \
                "server=$host" \
                "function=$FUNCTION" \
                "rc=$rc" \
                "duration=${duration}s"
        else
            log ERROR EXEC_FAILED \
                "server=$host" \
                "function=$FUNCTION" \
                "rc=$rc" \
                "duration=${duration}s"
        fi

        exit "$rc"
    )
}

# ------------------------------------------------------------------
# Recherche d'une paire de production
# ------------------------------------------------------------------

find_pair() {
    local target="$1"
    local entry
    local pair server_a server_b

    for entry in "${PROD_PAIRS[@]}"; do
        IFS=':' read -r pair server_a server_b <<< "$entry"

        if [[ "$pair" == "$target" ]]; then
            echo "$server_a:$server_b"
            return 0
        fi
    done

    return 1
}

# ------------------------------------------------------------------
# Paramètres
# ------------------------------------------------------------------

SERVER_TARGET=""
FUNCTION=""

while getopts ":s:f:h" opt; do
    case "$opt" in
        s)
            SERVER_TARGET="$OPTARG"
            ;;
        f)
            FUNCTION="$OPTARG"
            ;;
        h)
            echo "Usage : $0 -s <serveur|ALL|BACKUP> -f <fonction>"
            exit 0
            ;;
        :)
            echo "Option -$OPTARG : argument manquant" >&2
            exit 1
            ;;
        \?)
            echo "Option inconnue : -$OPTARG" >&2
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------
# Contrôle des paramètres
# ------------------------------------------------------------------

# Si -s est absent ou vide, aucune action.
if [[ -z "$SERVER_TARGET" ]]; then
    exit 0
fi

if [[ -z "$FUNCTION" ]]; then
    echo "La fonction -f est obligatoire." >&2
    exit 1
fi

if [[ ! "$FUNCTION" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Nom de fonction invalide." >&2
    exit 1
fi

SCRIPT="$SCRIPTS_DIR/${FUNCTION}.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "Script métier introuvable : $SCRIPT" >&2
    exit 1
fi

# ------------------------------------------------------------------
# Début de la demande
# ------------------------------------------------------------------

log INFO REQUEST_START \
    "function=$FUNCTION" \
    "target=$SERVER_TARGET" \
    "pid=$$"

# ------------------------------------------------------------------
# Construction de la liste des serveurs à traiter
# ------------------------------------------------------------------

declare -a JOBS=()

case "$SERVER_TARGET" in

    # --------------------------------------------------------------
    # Tous les serveurs actifs de production + préproduction
    # --------------------------------------------------------------

    ALL)

        for entry in "${PROD_PAIRS[@]}"; do
            IFS=':' read -r pair server_a server_b <<< "$entry"

            host="$(select_server "$server_a" "$server_b" ACTIVE)"

            if [[ -n "$host" ]]; then
                JOBS+=("$host")
            fi
        done

        # Préproduction : serveurs autonomes
        JOBS+=("${PREPROD_SERVERS[@]}")

        ;;

    # --------------------------------------------------------------
    # Serveurs passifs de production uniquement
    # --------------------------------------------------------------

    BACKUP)

        for entry in "${PROD_PAIRS[@]}"; do
            IFS=':' read -r pair server_a server_b <<< "$entry"

            host="$(select_server "$server_a" "$server_b" BACKUP)"

            if [[ -n "$host" ]]; then
                JOBS+=("$host")
            fi
        done

        ;;

    # --------------------------------------------------------------
    # Alias d'une paire : sélection du serveur actif
    # --------------------------------------------------------------

    CTMP*)

        if pair_info="$(find_pair "$SERVER_TARGET")"; then

            IFS=':' read -r server_a server_b <<< "$pair_info"

            host="$(select_server "$server_a" "$server_b" ACTIVE)"

            if [[ -n "$host" ]]; then
                JOBS+=("$host")
            fi

        else
            # Serveur explicitement ciblé
            JOBS+=("$SERVER_TARGET")
        fi

        ;;

    # --------------------------------------------------------------
    # Serveur explicitement ciblé
    # --------------------------------------------------------------

    *)
        JOBS+=("$SERVER_TARGET")
        ;;

esac

# ------------------------------------------------------------------
# Aucun serveur disponible ou sélectionné
# ------------------------------------------------------------------

if (( ${#JOBS[@]} == 0 )); then
    log WARN NO_SERVER_SELECTED \
        "function=$FUNCTION" \
        "target=$SERVER_TARGET"

    log INFO REQUEST_END \
        "function=$FUNCTION" \
        "target=$SERVER_TARGET" \
        "total=0" \
        "rc=0"

    exit 0
fi

# ------------------------------------------------------------------
# Lancement parallèle
# ------------------------------------------------------------------

declare -a PIDS=()

for host in "${JOBS[@]}"; do

    log INFO SERVER_SELECTED \
        "server=$host" \
        "function=$FUNCTION"

    run "$host" &
    PIDS+=("$!")
done

# ------------------------------------------------------------------
# Attente des traitements et bilan
# ------------------------------------------------------------------

TOTAL=${#PIDS[@]}
SUCCESS=0
FAILED=0
SKIPPED=0
GLOBAL_RC=0

for pid in "${PIDS[@]}"; do

    wait "$pid"
    rc=$?

    case "$rc" in
        0)
            ((SUCCESS += 1))
            ;;
        2)
            ((SKIPPED += 1))
            ;;
        *)
            ((FAILED += 1))
            GLOBAL_RC=1
            ;;
    esac

done

log INFO REQUEST_END \
    "function=$FUNCTION" \
    "target=$SERVER_TARGET" \
    "total=$TOTAL" \
    "success=$SUCCESS" \
    "failed=$FAILED" \
    "skipped=$SKIPPED" \
    "rc=$GLOBAL_RC"

exit "$GLOBAL_RC"
