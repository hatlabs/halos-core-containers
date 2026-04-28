#!/bin/bash
# lib-hostnames.sh — Shared shell library for hostname-aware operations
#
# Sourced by:
#   - halos-core-containers/prestart.sh
#   - /usr/bin/configure-container-routing
#   - /usr/bin/reload-oidc-clients
#
# Provides parsing, validation, and querying of /etc/halos/hostnames.conf,
# the admin-managed hostname list that drives:
#   - TLS cert SANs (DNS + IP)
#   - Authelia per-hostname session.cookies entries
#   - OIDC redirect_uris (DNS only)
#   - Path-only Traefik routing (canonical used for OIDC issuer)
#
# Quoting contract: every consumer that expands a hostname into a shell
# argument, openssl SAN string, YAML scalar, or URL MUST quote/escape the
# value at the consumer site. Validation eliminates shell metacharacters
# as defense-in-depth; quoting is the primary defense.

# Configuration --------------------------------------------------------------

# Override via env for tests; defaults match production.
: "${HALOS_HOSTNAMES_FILE:=/etc/halos/hostnames.conf}"
: "${HALOS_HOSTNAMES_MAX:=16}"

# Pinned regexes (shell-portable; bash =~ ERE).
# RFC 1123 DNS: at least one dot, labels start/end alphanumeric.
HALOS_HOSTNAMES_DNS_RE='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$'
HALOS_HOSTNAMES_IPV4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
# IPv6: rough literal shape (colons and hex). Round-tripped via getent for soundness.
HALOS_HOSTNAMES_IPV6_RE='^[0-9a-fA-F:]+$'

# State (populated by halos_load_hostnames) ----------------------------------

# After halos_load_hostnames, these globals hold the parsed result:
#   HALOS_HOSTNAMES_CANONICAL  — first DNS entry (or ${hostname}.local fallback)
#   HALOS_HOSTNAMES_DNS[]      — DNS entries in input order (post-expansion, post-validation)
#   HALOS_HOSTNAMES_IPS[]      — IP entries in input order
#   HALOS_HOSTNAMES_FALLBACK   — "1" if loaded canonical is the default (not from a valid file entry), else "0"
#   HALOS_HOSTNAMES_FALLBACK_REASON — short human-readable cause when fallback is set

# Internal helpers -----------------------------------------------------------

_halos_log() {
    # Stable signature on the first token so journalctl greps cleanly.
    printf '%s\n' "$*" >&2
}

_halos_short_hostname() {
    hostname -s 2>/dev/null || hostname | cut -d. -f1
}

# Validate IPv4 octet bounds (regex only matches digit shape).
_halos_valid_ipv4() {
    local ip="$1" o1 o2 o3 o4
    IFS=. read -r o1 o2 o3 o4 <<<"$ip"
    [ -n "$o1" ] && [ -n "$o2" ] && [ -n "$o3" ] && [ -n "$o4" ] || return 1
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        # Reject leading zeros (canonical form only) and out-of-range.
        case "$octet" in
            0|[1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# Validate IPv6 via getent (round-trip parse). Avoids hand-rolled regex.
_halos_valid_ipv6() {
    local addr="$1"
    # Must contain at least one colon to be IPv6 (and not bare digits like "1").
    case "$addr" in *:*) ;; *) return 1 ;; esac
    [[ "$addr" =~ $HALOS_HOSTNAMES_IPV6_RE ]] || return 1
    # getent ahosts <ipv6> echoes the address back if parseable.
    getent ahosts "$addr" >/dev/null 2>&1
}

# Reject obvious shell-metacharacter and control-character contamination.
# Validation regex would already exclude most, but this is defense-in-depth.
_halos_has_dangerous_chars() {
    local s="$1"
    case "$s" in
        *' '*|*$'\t'*|*$'\n'*|*$'\r'*) return 0 ;;
        *'`'*) return 0 ;;
        *'$'*) return 0 ;;
        *'\'*) return 0 ;;
        *'"'*) return 0 ;;
        *"'"*) return 0 ;;
    esac
    # Reject NUL and ASCII control chars (POSIX class).
    [[ "$s" =~ [[:cntrl:]] ]] && return 0
    return 1
}

# Expand the literal token ${hostname} (and only that token) per line.
_halos_expand_line() {
    local line="$1"
    local short
    short="$(_halos_short_hostname)"
    printf '%s' "${line//\$\{hostname\}/$short}"
}

# Set fallback state and emit a diagnostic.
_halos_set_fallback() {
    local reason="$1"
    HALOS_HOSTNAMES_FALLBACK=1
    HALOS_HOSTNAMES_FALLBACK_REASON="$reason"
    _halos_log "HALOS_HOSTNAMES_FALLBACK: $reason — falling back to single-SAN default"
}

# Public API -----------------------------------------------------------------

# halos_load_hostnames
#   Parse $HALOS_HOSTNAMES_FILE, populate state globals.
#   Always returns 0 — fallback is signaled via HALOS_HOSTNAMES_FALLBACK,
#   never via exit status (consumers must boot in fallback mode).
halos_load_hostnames() {
    HALOS_HOSTNAMES_DNS=()
    HALOS_HOSTNAMES_IPS=()
    HALOS_HOSTNAMES_CANONICAL=""
    HALOS_HOSTNAMES_FALLBACK=0
    HALOS_HOSTNAMES_FALLBACK_REASON=""

    local file="$HALOS_HOSTNAMES_FILE"
    local default_canonical
    default_canonical="$(_halos_short_hostname).local"

    if [ ! -e "$file" ]; then
        _halos_set_fallback "config file not found: $file"
        HALOS_HOSTNAMES_CANONICAL="$default_canonical"
        HALOS_HOSTNAMES_DNS=("$default_canonical")
        return 0
    fi

    if [ ! -r "$file" ]; then
        _halos_set_fallback "config file not readable: $file"
        HALOS_HOSTNAMES_CANONICAL="$default_canonical"
        HALOS_HOSTNAMES_DNS=("$default_canonical")
        return 0
    fi

    local line raw expanded
    local entry_count=0
    local had_invalid=0
    local first_invalid_reason=""

    while IFS= read -r raw || [ -n "$raw" ]; do
        # Strip leading/trailing whitespace.
        line="${raw#"${raw%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        # Skip blanks and comments.
        [ -z "$line" ] && continue
        case "$line" in '#'*) continue ;; esac

        entry_count=$((entry_count + 1))
        if [ "$entry_count" -gt "$HALOS_HOSTNAMES_MAX" ]; then
            had_invalid=1
            first_invalid_reason="${first_invalid_reason:-cap exceeded (max $HALOS_HOSTNAMES_MAX entries)}"
            break
        fi

        expanded="$(_halos_expand_line "$line")"

        if _halos_has_dangerous_chars "$expanded"; then
            had_invalid=1
            first_invalid_reason="${first_invalid_reason:-rejected entry with dangerous characters}"
            continue
        fi

        # Classify: IPv4, IPv6, DNS, or invalid.
        if [[ "$expanded" =~ $HALOS_HOSTNAMES_IPV4_RE ]]; then
            if _halos_valid_ipv4 "$expanded"; then
                HALOS_HOSTNAMES_IPS+=("$expanded")
            else
                had_invalid=1
                first_invalid_reason="${first_invalid_reason:-invalid IPv4 entry: $expanded}"
            fi
        elif _halos_valid_ipv6 "$expanded"; then
            HALOS_HOSTNAMES_IPS+=("$expanded")
        elif [[ "$expanded" =~ $HALOS_HOSTNAMES_DNS_RE ]]; then
            HALOS_HOSTNAMES_DNS+=("$expanded")
        else
            had_invalid=1
            first_invalid_reason="${first_invalid_reason:-invalid hostname entry: $expanded}"
        fi
    done < "$file"

    if [ "$had_invalid" -eq 1 ]; then
        _halos_set_fallback "$first_invalid_reason"
        HALOS_HOSTNAMES_DNS=("$default_canonical")
        HALOS_HOSTNAMES_IPS=()
        HALOS_HOSTNAMES_CANONICAL="$default_canonical"
        return 0
    fi

    if [ "${#HALOS_HOSTNAMES_DNS[@]}" -eq 0 ]; then
        _halos_set_fallback "no valid DNS entries in $file"
        HALOS_HOSTNAMES_DNS=("$default_canonical")
        HALOS_HOSTNAMES_IPS=()
        HALOS_HOSTNAMES_CANONICAL="$default_canonical"
        return 0
    fi

    HALOS_HOSTNAMES_CANONICAL="${HALOS_HOSTNAMES_DNS[0]}"
    return 0
}

# Print the canonical hostname (first DNS entry, or fallback default).
halos_canonical_hostname() {
    [ -z "${HALOS_HOSTNAMES_CANONICAL:-}" ] && halos_load_hostnames
    printf '%s\n' "$HALOS_HOSTNAMES_CANONICAL"
}

# Print all DNS hostnames, one per line, in input order.
halos_dns_hostnames() {
    [ -z "${HALOS_HOSTNAMES_CANONICAL:-}" ] && halos_load_hostnames
    local h
    for h in "${HALOS_HOSTNAMES_DNS[@]}"; do
        printf '%s\n' "$h"
    done
}

# Print all hostnames (DNS + IP), one per line, DNS first then IPs.
halos_all_hostnames() {
    [ -z "${HALOS_HOSTNAMES_CANONICAL:-}" ] && halos_load_hostnames
    local h
    for h in "${HALOS_HOSTNAMES_DNS[@]}"; do
        printf '%s\n' "$h"
    done
    for h in "${HALOS_HOSTNAMES_IPS[@]}"; do
        printf '%s\n' "$h"
    done
}

# Print SHA256 of LC_ALL=C-sorted hostname list (64 hex chars, no trailing whitespace).
halos_hostnames_hash() {
    [ -z "${HALOS_HOSTNAMES_CANONICAL:-}" ] && halos_load_hostnames
    halos_all_hostnames | LC_ALL=C sort | sha256sum | awk '{print $1}'
}
