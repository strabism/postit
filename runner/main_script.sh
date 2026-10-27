#!/usr/bin/env bash

set -u

# ================================================================
# INITIALISATION
# ================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BASE_DIR/config/servers.conf"

LOG_DIR="$BASE_DIR/logs"
LOCK_DIR="$BASE_DIR/locks"

LOG_FILE="$LOG_DIR/logs_ctm.log"
LOG_LOCK="$LOCK_DIR/logs.lock"

mkdir -p "$LOG_DIR" "$LOCK_DIR"

# Un RUN_ID unique par lancement, partagé par tous les traitements.
RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"

# ================================================================
# JOURNALISATION
# ================================================================

log() {
    local level="$1"
    local event="$2"
    shift 2

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    (
        # Verrou très court : écriture et rotation uniquement.
        flock -x 200 || exit 1

        # Rotation du fichier si nécessaire.
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

# ================================================================
# DETECTION DU SERVEUR ACTIF
# ================================================================

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
    fi

    log INFO NC_CHECK \
        "server=$host" \
        "port=$ACTIVE_PORT" \
        "rc=$rc" \
        "status=NO_RESPONSE"

    return 1
}

# ================================================================
# SELECTION ACTIF / PASSIF
#
# ACTIVE : retourne le serveur actif.
# BACKUP : retourne le serveur passif.
# ================================================================

select_server() {
    local server_a="$1"
    local server_b="$2"
    local mode="$3"

    local active_a=0
    local active_b=0

    if is_active "$server_a"; then
        active_a=1
    fi

    if is_active "$server_b"; then
        active_b=1
    fi

    # Situation anormale : les deux répondent.
    if (( active_a == 1 && active_b == 1 )); then
        log ERROR PAIR_INCONSISTENT \
            "server_a=$server_a" \
            "server_b=$server_b"

        return 1
    fi

    # Le serveur A est actif.
    if (( active_a == 1 )); then
        if [[ "$mode" == "ACTIVE" ]]; then
            echo "$server_a"
        else
            echo "$server_b"
        fi

        return 0
    fi

    # Le serveur B est actif.
    if (( active_b == 1 )); then
        if [[ "$mode" == "ACTIVE" ]]; then
            echo "$server_b"
        else
            echo "$server_a"
        fi

        return 0
    fi

    # Aucun serveur actif.
    log WARN SERVER_UNAVAILABLE \
        "servers=$server_a,$server_b"

    return 1
}

# ================================================================
# RECHERCHE D'UNE PAIRE
# ================================================================

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

# ================================================================
# EXECUTION DU SCRIPT METIER
#
# Exécution locale sur le serveur d'outillage.
# Le serveur Control-M est transmis en argument $1.
# ================================================================

run() {
    local host="$1"

    (
        local lock_file
        local start_time
        local end_time
        local duration
        local rc

        lock_file="$LOCK_DIR/${FUNCTION}_${host}.lock"

        # Un verrou par fonction et par serveur.
        exec 200>"$lock_file"

        if ! flock -n 200; then
            log WARN LOCK_BUSY \
                "server=$host" \
                "function=$FUNCTION"

            # Code réservé au moteur pour signaler un traitement ignoré.
            exit 200
        fi

        log INFO LOCK_ACQUIRED \
            "server=$host" \
            "function=$FUNCTION"

        start_time="$(date +%s)"

        log INFO EXEC_START \
            "server=$host" \
            "function=$FUNCTION" \
            "pid=$BASHPID"

        # Le script métier gère lui-même ses opérations.
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

# ================================================================
# PARAMETRES
# ================================================================

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
            echo "Argument manquant pour -$OPTARG" >&2
            exit 1
            ;;
        \?)
            echo "Option inconnue : -$OPTARG" >&2
            exit 1
            ;;
    esac
done

# Pas de serveur ciblé : aucune action.
if [[ -z "$SERVER_TARGET" ]]; then
    exit 0
fi

if [[ -z "$FUNCTION" ]]; then
    echo "L'option -f est obligatoire." >&2
    exit 1
fi

if [[ ! "$FUNCTION" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Nom de fonction invalide." >&2
    exit 1
fi

SCRIPT="$BASE_DIR/scripts/${FUNCTION}.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "Script métier introuvable : $SCRIPT" >&2
    exit 1
fi

# ================================================================
# DEBUT DE LA DEMANDE
# ================================================================

log INFO REQUEST_START \
    "function=$FUNCTION" \
    "target=$SERVER_TARGET" \
    "pid=$$"

# ================================================================
# CONSTRUCTION DE LA LISTE DES SERVEURS
# ================================================================

declare -a JOBS=()

case "$SERVER_TARGET" in

    # Tous les actifs de production + préproduction.
    ALL)

        for entry in "${PROD_PAIRS[@]}"; do
            IFS=':' read -r pair server_a server_b <<< "$entry"

            if host="$(select_server "$server_a" "$server_b" ACTIVE)"; then
                JOBS+=("$host")
            fi
        done

        JOBS+=("${PREPROD_SERVERS[@]}")

        ;;

    # Passifs de production uniquement.
    BACKUP)

        for entry in "${PROD_PAIRS[@]}"; do
            IFS=':' read -r pair server_a server_b <<< "$entry"

            if host="$(select_server "$server_a" "$server_b" BACKUP)"; then
                JOBS+=("$host")
            fi
        done

        ;;

    # Nom d'une paire : sélection de son actif.
    CTMP[0-9][0-9])

        if pair_info="$(find_pair "$SERVER_TARGET")"; then
            IFS=':' read -r server_a server_b <<< "$pair_info"

            if host="$(select_server "$server_a" "$server_b" ACTIVE)"; then
                JOBS+=("$host")
            fi
        else
            log ERROR UNKNOWN_PAIR "target=$SERVER_TARGET"
        fi

        ;;

    # Serveur explicitement ciblé.
    *)
        if [[ "$SERVER_TARGET" =~ ^[a-zA-Z0-9.-]+$ ]]; then
            JOBS+=("$SERVER_TARGET")
        else
            echo "Nom de serveur invalide." >&2
            exit 1
        fi
        ;;

esac

# ================================================================
# AUCUN SERVEUR SELECTIONNE
# ================================================================

if (( ${#JOBS[@]} == 0 )); then
    log WARN NO_SERVER_SELECTED \
        "function=$FUNCTION" \
        "target=$SERVER_TARGET"

    log INFO REQUEST_END \
        "function=$FUNCTION" \
        "target=$SERVER_TARGET" \
        "total=0" \
        "success=0" \
        "failed=0" \
        "skipped=0" \
        "rc=0"

    exit 0
fi

# ================================================================
# LANCEMENT PARALLELE
# ================================================================

declare -a PIDS=()

for host in "${JOBS[@]}"; do

    log INFO SERVER_SELECTED \
        "server=$host" \
        "function=$FUNCTION"

    run "$host" &
    PIDS+=("$!")

done

# ================================================================
# ATTENTE ET BILAN
# ================================================================

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
        200)
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
