#!/usr/bin/env bash
# Tests for assets/lib-hostnames.sh
#
# Run from repo root:
#   bash tests/test-lib-hostnames.sh
#
# Each test is a function prefixed with `test_`. Failures print a diagnostic
# and bump FAILS; the script exits non-zero if any test failed.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/assets/lib-hostnames.sh"

if [ ! -f "$LIB" ]; then
    echo "lib-hostnames.sh not found at $LIB" >&2
    exit 2
fi

PASSES=0
FAILS=0
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Colors only when stdout is a TTY.
if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; RESET=""
fi

# Reload the lib in a fresh subshell context (so test isolation is real).
# Each test function runs in this script process, but we reset state explicitly.
_reset_state() {
    HALOS_HOSTNAMES_FILE="$1"
    unset HALOS_HOSTNAMES_DNS HALOS_HOSTNAMES_IPS
    unset HALOS_HOSTNAMES_CANONICAL HALOS_HOSTNAMES_FALLBACK
    unset HALOS_HOSTNAMES_FALLBACK_REASON
    # shellcheck source=/dev/null
    . "$LIB"
}

# assert_eq <actual> <expected> <msg>
assert_eq() {
    if [ "$1" = "$2" ]; then
        return 0
    fi
    printf '%s    actual:   %q\n    expected: %q\n' "$3" "$1" "$2" >&2
    return 1
}

run_test() {
    local name="$1"
    local out
    if out=$("$name" 2>&1); then
        PASSES=$((PASSES + 1))
        printf '%sPASS%s %s\n' "$GREEN" "$RESET" "$name"
    else
        FAILS=$((FAILS + 1))
        printf '%sFAIL%s %s\n%s\n' "$RED" "$RESET" "$name" "$out"
    fi
}

# Helper to fabricate a hostnames.conf
write_conf() {
    local path="$1"; shift
    printf '%s\n' "$@" > "$path"
}

# ---------------------------------------------------------------------------

test_happy_path_dns_and_ip() {
    local f="$TMPDIR_ROOT/happy.conf"
    write_conf "$f" "halosdev.local" "halosdev.example.com" "10.0.0.50"
    _reset_state "$f"
    halos_load_hostnames

    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "fallback should not fire on happy path"
    assert_eq "$(halos_canonical_hostname)" "halosdev.local" "canonical wrong"
    assert_eq "$(halos_dns_hostnames | tr '\n' ',')" "halosdev.local,halosdev.example.com," "DNS list wrong"
    assert_eq "$(halos_all_hostnames | tr '\n' ',')" "halosdev.local,halosdev.example.com,10.0.0.50," "all-list wrong"
}

test_comments_and_blank_lines_ignored() {
    local f="$TMPDIR_ROOT/comments.conf"
    {
        echo "# heading"
        echo ""
        echo "halosdev.local"
        echo "  # indented comment"
        echo ""
        echo "halosdev.example.com"
    } > "$f"
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "should parse cleanly"
    assert_eq "$(halos_dns_hostnames | wc -l | tr -d ' ')" "2" "expected 2 DNS entries"
}

test_missing_file_fallback() {
    _reset_state "$TMPDIR_ROOT/does-not-exist.conf"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "fallback should fire on missing file"
    local short; short="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"
    assert_eq "$(halos_canonical_hostname)" "${short}.local" "fallback canonical wrong"
}

test_empty_file_fallback() {
    local f="$TMPDIR_ROOT/empty.conf"
    : > "$f"
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "fallback should fire on empty file"
}

test_only_ips_fallback() {
    local f="$TMPDIR_ROOT/onlyips.conf"
    write_conf "$f" "10.0.0.1" "10.0.0.2"
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "fallback should fire when no DNS entries"
}

test_cap_exceeded_fallback() {
    local f="$TMPDIR_ROOT/cap.conf"
    : > "$f"
    local i
    for i in $(seq 1 17); do
        echo "h${i}.example.com" >> "$f"
    done
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "fallback should fire when cap exceeded"
}

test_invalid_entries_fallback() {
    local cases=(
        "foo..bar.com"
        "*.foo.com"
        ".foo.com"
        "myhost"
        "host with space"
    )
    local case
    for case in "${cases[@]}"; do
        local f="$TMPDIR_ROOT/inv.conf"
        printf '%s\n' "$case" > "$f"
        _reset_state "$f"
        halos_load_hostnames
        if [ "$HALOS_HOSTNAMES_FALLBACK" != "1" ]; then
            echo "expected fallback for invalid entry: $case" >&2
            return 1
        fi
    done
}

test_dangerous_chars_rejected() {
    local f="$TMPDIR_ROOT/dangerous.conf"
    printf '%s\n' 'foo`whoami`.example.com' > "$f"
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "backtick must trigger fallback"
}

test_unreadable_file_fallback() {
    local f="$TMPDIR_ROOT/unreadable.conf"
    write_conf "$f" "halosdev.local"
    chmod 0000 "$f"
    _reset_state "$f"
    halos_load_hostnames
    local fb="$HALOS_HOSTNAMES_FALLBACK"
    chmod 0644 "$f"
    # Skip when running as root (can read mode-0000 files).
    if [ "$(id -u)" = "0" ]; then
        return 0
    fi
    assert_eq "$fb" "1" "fallback should fire on unreadable file"
}

test_hostname_token_expansion() {
    local f="$TMPDIR_ROOT/expand.conf"
    write_conf "$f" '${hostname}.local' 'vpn.${hostname}.example.com'
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "expansion should produce valid entries"
    local short; short="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"
    assert_eq "$(halos_canonical_hostname)" "${short}.local" "canonical should be expanded"
    local list; list="$(halos_dns_hostnames | tr '\n' ',')"
    assert_eq "$list" "${short}.local,vpn.${short}.example.com," "expanded list wrong"
}

test_hash_stable_across_reorderings() {
    local fa="$TMPDIR_ROOT/order-a.conf"
    local fb="$TMPDIR_ROOT/order-b.conf"
    write_conf "$fa" "halosdev.local" "halosdev.example.com" "10.0.0.50"
    write_conf "$fb" "10.0.0.50" "halosdev.example.com" "halosdev.local"

    _reset_state "$fa"; halos_load_hostnames
    local ha; ha="$(halos_hostnames_hash)"
    _reset_state "$fb"; halos_load_hostnames
    local hb; hb="$(halos_hostnames_hash)"

    assert_eq "$ha" "$hb" "hash must be order-invariant"
    # 64 hex chars
    if ! [[ "$ha" =~ ^[0-9a-f]{64}$ ]]; then
        echo "hash format wrong: $ha" >&2
        return 1
    fi
}

test_hash_default_state_consistent() {
    local missing="$TMPDIR_ROOT/no-such.conf"
    local single="$TMPDIR_ROOT/single.conf"
    local short; short="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"
    write_conf "$single" "${short}.local"

    _reset_state "$missing"; halos_load_hostnames
    local h_missing; h_missing="$(halos_hostnames_hash)"

    _reset_state "$single"; halos_load_hostnames
    local h_single; h_single="$(halos_hostnames_hash)"

    assert_eq "$h_missing" "$h_single" "missing-file hash must match single-default-entry hash"
}

test_hash_changes_on_membership_change() {
    local f1="$TMPDIR_ROOT/m1.conf"
    local f2="$TMPDIR_ROOT/m2.conf"
    write_conf "$f1" "halosdev.local"
    write_conf "$f2" "halosdev.local" "halosdev.example.com"
    _reset_state "$f1"; halos_load_hostnames
    local h1; h1="$(halos_hostnames_hash)"
    _reset_state "$f2"; halos_load_hostnames
    local h2; h2="$(halos_hostnames_hash)"
    if [ "$h1" = "$h2" ]; then
        echo "hash should change when membership changes ($h1)" >&2
        return 1
    fi
}

test_invalid_ipv4_octet_rejected() {
    local f="$TMPDIR_ROOT/badip.conf"
    write_conf "$f" "halosdev.local" "10.0.0.999"
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "invalid IPv4 octet must trigger fallback"
}

test_expand_redirect_uri_no_placeholder() {
    local f="$TMPDIR_ROOT/exp1.conf"
    write_conf "$f" "halosdev.local" "halosdev.example.com"
    _reset_state "$f"
    halos_load_hostnames
    local out
    out=$(halos_expand_oidc_redirect_uri "https://literal.example.com/cb")
    assert_eq "$out" "https://literal.example.com/cb" "non-placeholder URI should pass through unchanged"
}

test_expand_redirect_uri_placeholder_per_dns() {
    local f="$TMPDIR_ROOT/exp2.conf"
    write_conf "$f" "halosdev.local" "halosdev.example.com" "10.0.0.50"
    _reset_state "$f"
    halos_load_hostnames
    local out; out=$(halos_expand_oidc_redirect_uri 'https://${HALOS_DOMAIN}/api/auth/callback' | tr '\n' ',')
    assert_eq "$out" "https://halosdev.local/api/auth/callback,https://halosdev.example.com/api/auth/callback," "placeholder must expand per DNS hostname (IPs excluded)"
}

test_expand_redirect_uri_subdomain_placeholder() {
    local f="$TMPDIR_ROOT/exp3.conf"
    write_conf "$f" "halosdev.local" "halosdev.example.com"
    _reset_state "$f"
    halos_load_hostnames
    local out; out=$(halos_expand_oidc_redirect_uri 'https://auth.${HALOS_DOMAIN}/cb' | tr '\n' ',')
    assert_eq "$out" "https://auth.halosdev.local/cb,https://auth.halosdev.example.com/cb," "subdomain placeholder must expand"
}

test_expand_redirect_uri_default_fallback() {
    _reset_state "$TMPDIR_ROOT/missing.conf"
    halos_load_hostnames
    local short; short="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"
    local out; out=$(halos_expand_oidc_redirect_uri 'https://${HALOS_DOMAIN}/cb' | tr '\n' ',')
    assert_eq "$out" "https://${short}.local/cb," "fallback should expand to single canonical URI"
}

# ---------------------------------------------------------------------------

run_test test_happy_path_dns_and_ip
run_test test_comments_and_blank_lines_ignored
run_test test_missing_file_fallback
run_test test_empty_file_fallback
run_test test_only_ips_fallback
run_test test_cap_exceeded_fallback
run_test test_invalid_entries_fallback
run_test test_dangerous_chars_rejected
run_test test_unreadable_file_fallback
run_test test_hostname_token_expansion
run_test test_hash_stable_across_reorderings
run_test test_hash_default_state_consistent
run_test test_hash_changes_on_membership_change
run_test test_invalid_ipv4_octet_rejected
run_test test_expand_redirect_uri_no_placeholder
run_test test_expand_redirect_uri_placeholder_per_dns
run_test test_expand_redirect_uri_subdomain_placeholder
run_test test_expand_redirect_uri_default_fallback

echo ""
echo "Passed: $PASSES   Failed: $FAILS"
[ "$FAILS" -eq 0 ]
