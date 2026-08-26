#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Completion manifest (defs/defs-governance-repo.md): soubor
# state/.completion-manifest.tsv v gov repu, řádek <ghName>\t<ghProjectKey>\t
# <archived>. Publikace stavu spravovaných rep pro klientskou TAB completion
# cache; zapisuje výhradně workflow. Modul pracuje nad lokálním checkoutem
# gov repa a každou provedenou operaci eviduje pro replay po rebase
# (_gh-governance-state-push, ochrana sdíleného souboru před `-X ours`).
# Závislosti: gh-common-defs.sh (GH_REPO_PREFIX, _GH_GHNAME_REGEX),
# lib/gh-governance-state.sh (_gh-governance-checkout-root),
# lib/gh-governance-reconcile.sh (_gh-governance-classify, jen pro rebuild).
[[ -n "${_GH_GOVERNANCE_MANIFEST_LOADED:-}" ]] && \
  declare -F _gh-governance-manifest-upsert >/dev/null && return 0
_GH_GOVERNANCE_MANIFEST_LOADED=1

# Deník operací běhu pro _gh-governance-manifest-replay; položky
# "upsert\t<key>\t<ghName>\t<archived>", "remove\t<key>\t<ghName>",
# "rebuild\t<soubor s obsahem>".
declare -a _GH_GOVERNANCE_MANIFEST_OPS=()

_gh-governance-manifest-file() {
  # Vypíše cestu manifestu v checkoutu gov repa.
  # Použití: _gh-governance-manifest-file
  local _root
  _root=$(_gh-governance-checkout-root) || return 1
  printf '%s\n' "$_root/state/.completion-manifest.tsv"
}

_gh-governance-manifest-validate-args() {
  # Interní: validace <projectKey> a <ghName> proti formátům z defs/defs.md.
  # Použití: _gh-governance-manifest-validate-args <projectKey> <ghName>
  local _key="$1" _name="$2"
  if ! _gh-match "$_key" '^[a-z0-9]+$'; then
    echo "Chyba: projectKey '$_key' neodpovídá formátu ^[a-z0-9]+$ (viz defs/defs.md)." >&2
    return 1
  fi
  if ! _gh-match "$_name" "$_GH_GHNAME_REGEX"; then
    echo "Chyba: ghName '$_name' neodpovídá formátu $_GH_GHNAME_REGEX (viz defs/defs.md)." >&2
    return 1
  fi
}

_gh-governance-manifest-write-atomic() {
  # Interní: zapíše stdin atomicky (tmp + mv) do manifestu; obsah setřídí
  # (klíč, název) – deterministický výstup minimalizuje rebase konflikty.
  # LC_ALL=C: řazení po bajtech nezávisle na locale stroje – jinak by
  # zapisovatelé s různými locale soubor přeuspořádávali
  # (docs/bash/locale-rozsahy-regex-validace.md).
  # Použití: ... | _gh-governance-manifest-write-atomic
  local _file _tmp
  _file=$(_gh-governance-manifest-file) || return 1
  mkdir -p "$(dirname "$_file")" || return 1
  _tmp=$(mktemp "${_file}.tmp.XXXXXX") || return 1
  if ! LC_ALL=C sort -t$'\t' -k2,2 -k1,1 > "$_tmp"; then
    rm -f "$_tmp"
    return 1
  fi
  mv "$_tmp" "$_file"
}

_gh-governance-manifest-apply-upsert() {
  # Interní: upsert řádku v pracovní kopii (bez zápisu do deníku operací).
  # Použití: _gh-governance-manifest-apply-upsert <projectKey> <ghName> <true|false>
  local _key="$1" _name="$2" _archived="$3" _file
  _file=$(_gh-governance-manifest-file) || return 1
  {
    [[ -f "$_file" ]] && awk -F'\t' -v k="$_key" -v n="$_name" '!($1==n && $2==k)' "$_file"
    printf '%s\t%s\t%s\n' "$_name" "$_key" "$_archived"
  } | _gh-governance-manifest-write-atomic
}

_gh-governance-manifest-apply-remove() {
  # Interní: odebrání řádku v pracovní kopii (bez zápisu do deníku operací);
  # chybějící řádek i soubor jsou v pořádku (idempotence).
  # Použití: _gh-governance-manifest-apply-remove <projectKey> <ghName>
  local _key="$1" _name="$2" _file
  _file=$(_gh-governance-manifest-file) || return 1
  [[ -f "$_file" ]] || return 0
  awk -F'\t' -v k="$_key" -v n="$_name" '!($1==n && $2==k)' "$_file" \
    | _gh-governance-manifest-write-atomic
}

_gh-governance-manifest-upsert() {
  # Upsert řádku manifestu (založení repa, přepnutí archived) a evidence
  # operace pro replay. archived = true|false.
  # Použití: _gh-governance-manifest-upsert <projectKey> <ghName> <true|false>
  local _key="$1" _name="$2" _archived="$3"
  _gh-governance-manifest-validate-args "$_key" "$_name" || return 1
  case "$_archived" in
    true|false) ;;
    *) echo "Chyba: archived musí být true|false (je '$_archived')." >&2; return 1 ;;
  esac
  _gh-governance-manifest-apply-upsert "$_key" "$_name" "$_archived" || return 1
  _GH_GOVERNANCE_MANIFEST_OPS+=("upsert"$'\t'"$_key"$'\t'"$_name"$'\t'"$_archived")
}

_gh-governance-manifest-remove() {
  # Odebrání řádku manifestu (zaniklé repo) a evidence operace pro replay;
  # idempotentní.
  # Použití: _gh-governance-manifest-remove <projectKey> <ghName>
  local _key="$1" _name="$2"
  _gh-governance-manifest-validate-args "$_key" "$_name" || return 1
  _gh-governance-manifest-apply-remove "$_key" "$_name" || return 1
  _GH_GOVERNANCE_MANIFEST_OPS+=("remove"$'\t'"$_key"$'\t'"$_name")
}

_gh-governance-manifest-rebuild() {
  # Plná přestavba manifestu z výpisu rep organizace (formát
  # _gh-governance-org-repos-list: name\tarchived\tbranch\ttopicsCSV).
  # Bere jen třídu `spravovane` (obě podmnožiny archived). Namerefy naplní
  # počty přidaných/odebraných řádků vůči předchozí verzi. Eviduje operaci
  # pro replay (kopie nového obsahu).
  # Použití: _gh-governance-manifest-rebuild <listing_file> <added_ref> <removed_ref>
  local _listing_file="$1"
  declare -n _added_ref="$2" _removed_ref="$3"
  local _file _new _old_sorted _new_sorted _keep
  local _name _archived _branch _topics _extra _class _value
  _added_ref=0; _removed_ref=0
  _file=$(_gh-governance-manifest-file) || return 1
  [[ -f "$_listing_file" ]] || {
    echo "Chyba: Soubor s výpisem rep '$_listing_file' neexistuje." >&2
    return 1
  }
  _new=$(mktemp) || return 1
  while IFS=$'\t' read -r _name _archived _branch _topics _extra; do
    [[ -n "$_name" ]] || continue
    IFS=$'\t' read -r _class _value <<< "$(_gh-governance-classify "$_name" "$_topics")"
    [[ "$_class" == spravovane ]] || continue
    printf '%s\t%s\t%s\n' "${_name#"${GH_REPO_PREFIX}-${_value}-"}" "$_value" "$_archived"
  done < "$_listing_file" > "$_new" || { rm -f "$_new"; return 1; }

  _old_sorted=$(mktemp) || { rm -f "$_new"; return 1; }
  _new_sorted=$(mktemp) || { rm -f "$_new" "$_old_sorted"; return 1; }
  [[ -f "$_file" ]] && LC_ALL=C sort "$_file" > "$_old_sorted"
  LC_ALL=C sort "$_new" > "$_new_sorted"
  _added_ref=$(comm -13 "$_old_sorted" "$_new_sorted" | grep -c . || true)
  _removed_ref=$(comm -23 "$_old_sorted" "$_new_sorted" | grep -c . || true)
  rm -f "$_old_sorted" "$_new_sorted"

  if ! _gh-governance-manifest-write-atomic < "$_new"; then
    rm -f "$_new"
    return 1
  fi
  # Kopie obsahu pro replay zůstává do konce běhu (mktemp v TMPDIR).
  _keep=$(mktemp) || { rm -f "$_new"; return 1; }
  cp "$_new" "$_keep" || { rm -f "$_new" "$_keep"; return 1; }
  rm -f "$_new"
  _GH_GOVERNANCE_MANIFEST_OPS+=("rebuild"$'\t'"$_keep")
}

_gh-governance-manifest-replay() {
  # Idempotentně znovu aplikuje evidované operace běhu na aktuální pracovní
  # kopii – volá ho _gh-governance-state-push po každém rebase, aby `-X ours`
  # nezahodil lokální úpravy sdíleného manifestu.
  # Použití: _gh-governance-manifest-replay
  local _op _type _a1 _a2 _a3
  for _op in "${_GH_GOVERNANCE_MANIFEST_OPS[@]}"; do
    IFS=$'\t' read -r _type _a1 _a2 _a3 <<< "$_op"
    case "$_type" in
      upsert)  _gh-governance-manifest-apply-upsert "$_a1" "$_a2" "$_a3" || return 1 ;;
      remove)  _gh-governance-manifest-apply-remove "$_a1" "$_a2" || return 1 ;;
      rebuild) _gh-governance-manifest-write-atomic < "$_a1" || return 1 ;;
      *) echo "Chyba: Neznámá operace manifestu '$_type'." >&2; return 1 ;;
    esac
  done
  return 0
}
