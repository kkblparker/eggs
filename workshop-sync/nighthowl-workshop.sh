#!/bin/bash
# NightHowl Workshop sync - runs before the game server on every start.
#
# Reads the mod list the panel's Steam Workshop tab manages (WORKSHOP_MODS,
# "@<id>;@<id>;" - plain ids and commas are accepted too), downloads/updates
# each item with steamcmd (anonymous login works for Barotrauma and Starbound
# Workshop content), then wires the items into the game:
#
#   barotrauma : LocalMods/ws_<id> -> the downloaded item, and the
#                <regularpackages> list in config_player.xml (in list order).
#                Packages that aren't ws_* (manually uploaded mods) are kept.
#   starbound  : mods/ws_<id>_<n>.pak -> each .pak in the downloaded item.
#
# Anything this script added earlier but is no longer in the list is removed
# (links, config entries and the downloaded files). It never touches files it
# didn't create. A failed download never stops the server from starting.
#
# Usage: bash nighthowl-workshop.sh <barotrauma|starbound>

GAME="$1"
APPID="${WORKSHOP_APPID}"
ROOT="/home/container"
CONTENT="${ROOT}/steamapps/workshop/content/${APPID}"
STEAMCMD="${ROOT}/steamcmd/steamcmd.sh"

log() { echo -e "\033[1;36m[workshop]\033[0m $*"; }

cd "${ROOT}" || exit 0

if [ -z "${GAME}" ] || [ -z "${APPID}" ]; then
    log "not configured (game='${GAME}' appid='${APPID}'), skipping"
    exit 0
fi

# Parse the list: keep digits-only ids, drop duplicates, keep order.
mapfile -t IDS < <(printf '%s' "${WORKSHOP_MODS}" | tr ';, ' '\n\n\n' | sed 's/^@//' | grep -E '^[0-9]+$' | awk '!seen[$0]++')

in_list() {
    local id
    for id in "${IDS[@]}"; do [ "$id" = "$1" ] && return 0; done
    return 1
}

# --- download / update ------------------------------------------------------
if [ "${#IDS[@]}" -gt 0 ]; then
    if [ ! -x "${STEAMCMD}" ]; then
        log "steamcmd not found at ${STEAMCMD} - reinstall the server to fix. Skipping downloads."
    else
        log "updating ${#IDS[@]} Workshop item(s)..."
        args=()
        for id in "${IDS[@]}"; do args+=(+workshop_download_item "${APPID}" "${id}" validate); done
        HOME="${ROOT}" "${STEAMCMD}" +force_install_dir "${ROOT}" +login anonymous "${args[@]}" +quit \
            | grep -E "Success|ERROR|Error|Failed|failed" | sed 's/^/  /'

        # steamcmd sometimes times out on big items - retry the missing ones once each.
        for id in "${IDS[@]}"; do
            if [ ! -d "${CONTENT}/${id}" ]; then
                log "retrying ${id}..."
                HOME="${ROOT}" "${STEAMCMD}" +force_install_dir "${ROOT}" +login anonymous \
                    +workshop_download_item "${APPID}" "${id}" validate +quit \
                    | grep -E "Success|ERROR|Error|Failed|failed" | sed 's/^/  /'
            fi
            [ -d "${CONTENT}/${id}" ] || log "WARNING: item ${id} could not be downloaded - starting without it"
        done
    fi
fi

# --- remove items that were taken off the list ---------------------------------
if [ -d "${CONTENT}" ]; then
    for dir in "${CONTENT}"/*/; do
        [ -d "$dir" ] || continue
        id="$(basename "$dir")"
        if ! in_list "$id"; then
            log "removing ${id} (no longer in the mod list)"
            rm -rf "${CONTENT:?}/${id}"
        fi
    done
fi

# --- game specific wiring ------------------------------------------------------
case "${GAME}" in
barotrauma)
    mkdir -p LocalMods
    # Drop our old links, then relink everything currently downloaded.
    find LocalMods -maxdepth 1 -name 'ws_*' -type l -delete
    ENABLED=()
    for id in "${IDS[@]}"; do
        if [ -f "${CONTENT}/${id}/filelist.xml" ]; then
            ln -sfn "${CONTENT}/${id}" "LocalMods/ws_${id}"
            ENABLED+=("LocalMods/ws_${id}/filelist.xml")
        elif [ -d "${CONTENT}/${id}" ]; then
            log "WARNING: item ${id} has no filelist.xml - is it a Barotrauma mod? skipping"
        fi
    done

    CFG="config_player.xml"
    if [ ! -f "$CFG" ]; then
        # First start: give the game a minimal config; it fills in the rest itself.
        printf '<?xml version="1.0" encoding="utf-8"?>\n<config>\n  <contentpackages>\n    <corepackage path="Content/ContentPackages/Vanilla.xml" />\n    <regularpackages>\n    </regularpackages>\n  </contentpackages>\n</config>\n' > "$CFG"
    fi

    NEW_LINES=""
    for p in "${ENABLED[@]}"; do NEW_LINES+="      <package path=\"${p}\" />"$'\n'; done
    export NEW_LINES

    # Rewrite only the <regularpackages> block: keep non-ws_ entries, drop old ws_
    # entries, append the current list in order. Entries are handled per element,
    # not per line (the game writes some elements with one attribute per line).
    # Handles a self-closing or missing block.
    awk '
        BEGIN { add = ENVIRON["NEW_LINES"]; done = 0; inblk = 0; buf = "" }
        function emit() { if (!done) { printf "%s", add; done = 1 } }
        function flush(   n, parts, i, elem) {
            n = split(buf, parts, "<package")
            for (i = 2; i <= n; i++) {
                elem = "<package" parts[i]
                sub(/[ \t\r\n]+$/, "", elem)
                if (elem ~ /LocalMods\/ws_[0-9]+\//) continue
                print "      " elem
            }
            buf = ""
        }
        tolower($0) ~ /<regularpackages[^>]*\/>/ {
            sub(/<[rR]egular[pP]ackages[^>]*\/>/, "<regularpackages>"); print
            emit(); print "    </regularpackages>"; next
        }
        tolower($0) ~ /<regularpackages/ { inblk = 1; print; next }
        inblk && tolower($0) ~ /<\/regularpackages>/ { flush(); emit(); inblk = 0; print; next }
        inblk { buf = buf $0 "\n"; next }
        !done && tolower($0) ~ /<\/contentpackages>/ {
            print "    <regularpackages>"; emit(); print "    </regularpackages>"; print; next
        }
        { print }
    ' "$CFG" > "${CFG}.tmp" && mv "${CFG}.tmp" "$CFG"
    log "${#ENABLED[@]} Workshop mod(s) enabled"
    ;;

starbound)
    mkdir -p mods
    find mods -maxdepth 1 -name 'ws_*.pak' -type l -delete
    count=0
    for id in "${IDS[@]}"; do
        [ -d "${CONTENT}/${id}" ] || continue
        n=0
        for pak in "${CONTENT}/${id}"/*.pak; do
            [ -f "$pak" ] || continue
            ln -sfn "$pak" "mods/ws_${id}_${n}.pak"
            n=$((n + 1))
        done
        if [ "$n" -eq 0 ]; then
            log "WARNING: item ${id} has no .pak file - is it a Starbound mod? skipping"
        else
            count=$((count + 1))
        fi
    done
    log "${count} Workshop mod(s) enabled"
    ;;

*)
    log "unknown game '${GAME}', nothing wired"
    ;;
esac

exit 0
