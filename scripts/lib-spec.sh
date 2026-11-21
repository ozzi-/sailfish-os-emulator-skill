# ═════════════════════════════════════════════════════════════
# lib-spec.sh — Harbour RPM spec parsing (shared, pure, side-effect-free)
#
# Sourced by deploy.sh and build-phone.sh. No lock guard, no VM access,
# no output — so it can be exercised directly from scripts/smoke.sh
# (deploy.sh itself is lock-guarded and can't be sourced for that).
#
# Why a lib: real-world Harbour specs name their package several ways.
# deploy.sh used to do `grep '^%define name'` which silently fell back to
# the spec FILENAME for the common `Name: harbour-foo` form — correct only
# when filename == package name. These helpers resolve all the forms.
# ═════════════════════════════════════════════════════════════

# _sfos_spec_field <spec> <Field>
#   Print the first value of a top-level RPM tag (`Name:`, `Version:`,
#   `Release:`), comment-stripped, first token only. Empty if absent.
_sfos_spec_field() {
    local spec="$1" field="$2"
    sed -n "s/^[[:space:]]*${field}:[[:space:]]*//p" "$spec" 2>/dev/null \
        | head -1 \
        | sed 's/#.*$//' \
        | awk '{print $1}'
}

# _sfos_spec_define <spec> <macro>
#   Print the value of `%define <macro> ...` (first token), empty if absent.
#   Anchored so `%define appname` is NOT matched as macro `name`.
_sfos_spec_define() {
    local spec="$1" macro="$2"
    sed -n "s/^[[:space:]]*%define[[:space:]]\{1,\}${macro}[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p" "$spec" 2>/dev/null \
        | head -1
}

# _sfos_resolve <spec> <Field> <fallback-macro>
#   Resolve a spec field that may be a literal, a macro (%{name}), or absent:
#     1. `Field: literal`                    → literal
#     2. `Field: %{X}` + `%define X literal` → literal (X = fallback-macro)
#   Prints nothing if it can't be resolved.
_sfos_resolve() {
    local spec="$1" field="$2" macro="${3:-}"
    local v
    v=$(_sfos_spec_field "$spec" "$field")
    [[ -n "$v" ]] || return 0
    if [[ "$v" == "%{"*"}" ]]; then
        # v looks like "%{name}" / "%{appname}" → pull out the macro name.
        v=$(printf '%s' "$v" | sed -n 's/^%{\(.*\)}$/\1/p')
        [[ -n "$v" ]] || return 0
        v=$(_sfos_spec_define "$spec" "$v")
    fi
    [[ -n "$v" ]] && printf '%s' "$v"
    return 0
}

# spec_app_name <spec>  → package name (harbour-*)
#   Tries: literal `Name:` → macro-resolved `Name:` → spec filename.
spec_app_name() {
    local spec="$1" v
    v=$(_sfos_resolve "$spec" "Name" "name")
    if [[ -n "$v" ]]; then
        printf '%s' "$v"
    else
        printf '%s' "$(basename "$spec" .spec)"
    fi
}

# spec_app_version <spec>  → package version (best effort, empty if unknown)
spec_app_version() {
    local spec="$1"
    _sfos_resolve "$spec" "Version" "version"
}

# spec_app_release <spec>  → package release (best effort, empty if unknown)
spec_app_release() {
    local spec="$1"
    _sfos_resolve "$spec" "Release" "release"
}
