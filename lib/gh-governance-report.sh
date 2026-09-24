#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Report kontroly konzistence (reconcile; položky dle defs/defs.md) a životní
# cyklus reconcile issue (závazně defs/defs-governance-repo.md, sekce reconcile issue).
# Itemy se sbírají jako TSV řádky `level\ttyp\trepo\tdetail`
# do souboru; render do souhrnu běhu ($GITHUB_STEP_SUMMARY) a těla issue
# (jen warning+error + odkaz na běh) dělají render funkce.
# Závislosti: gh-common-defs.sh (_require_vars).
[[ -n "${_GH_GOVERNANCE_REPORT_LOADED:-}" ]] && \
  declare -F _gh-governance-report-add >/dev/null && return 0
_GH_GOVERNANCE_REPORT_LOADED=1

_GH_GOVERNANCE_REPORT_LABEL=reconcile-report

_gh-governance-report-init() {
  # Založí (vyprázdní) soubor reportu a zapamatuje si jeho cestu.
  # Použití: _gh-governance-report-init <soubor>
  _GH_GOVERNANCE_REPORT_FILE="$1"
  : > "$_GH_GOVERNANCE_REPORT_FILE"
}

_gh-governance-report-add() {
  # Přidá položku reportu: úroveň, typ zjištění, dotčené repo/projekt, detail.
  # Tabulátory a nové řádky v detailu se nahrazují mezerou (TSV integrita).
  # Použití: _gh-governance-report-add <error|warning|info> <typ> <repo> <detail>
  local _level="$1" _type="$2" _repo="$3" _detail="$4"
  case "$_level" in
    error|warning|info) ;;
    *) echo "Chyba: Neznámá úroveň reportu '$_level'." >&2; return 1 ;;
  esac
  _detail="${_detail//$'\t'/ }"
  _detail="${_detail//$'\n'/ }"
  _type="${_type//$'\t'/ }"
  printf '%s\t%s\t%s\t%s\n' "$_level" "$_type" "$_repo" "$_detail" \
    >> "$_GH_GOVERNANCE_REPORT_FILE"
}

_gh-governance-report-count() {
  # Vypíše počet položek dané úrovně v souboru reportu.
  # Použití: _gh-governance-report-count <error|warning|info> [soubor]
  local _level="$1" _file="${2:-$_GH_GOVERNANCE_REPORT_FILE}"
  grep -c "^$_level	" "$_file" || true
}

_gh-governance-report-header() {
  # Vypíše závazný souhrn počtů dle urovní (začátek každého reportu).
  # Použití: _gh-governance-report-header [soubor]
  local _file="${1:-$_GH_GOVERNANCE_REPORT_FILE}"
  printf 'error: %s, warning: %s, info: %s\n' \
    "$(_gh-governance-report-count error "$_file")" \
    "$(_gh-governance-report-count warning "$_file")" \
    "$(_gh-governance-report-count info "$_file")"
}

_gh-governance-report-render() {
  # Vyrenderuje report jako markdown (souhrn počtů + tabulka položek);
  # volitelně jen úrovně error+warning. Výstup na stdout – volající ho
  # přesměruje do $GITHUB_STEP_SUMMARY nebo do těla issue.
  # Použití: _gh-governance-report-render [--errors-warnings-only] [soubor]
  local _only=false _file="$_GH_GOVERNANCE_REPORT_FILE" _a
  local _level _type _repo _detail
  for _a in "$@"; do
    case "$_a" in
      --errors-warnings-only) _only=true ;;
      *) _file="$_a" ;;
    esac
  done
  _gh-governance-report-header "$_file"
  echo ""
  if [[ ! -s "$_file" ]]; then
    echo "Žádná zjištění."
    return 0
  fi
  echo "| Úroveň | Zjištění | Repo/projekt | Detail |"
  echo "|---|---|---|---|"
  while IFS=$'\t' read -r _level _type _repo _detail; do
    [[ -z "$_level" ]] && continue
    if [[ "$_only" == true && "$_level" == info ]]; then
      continue
    fi
    printf '| %s | %s | %s | %s |\n' "$_level" "$_type" "$_repo" "$_detail"
  done < "$_file"
}

_gh-governance-report-issue-body() {
  # Sestaví tělo reconcile issue: jen warning+error položky + odkaz na běh.
  # Použití: _gh-governance-report-issue-body <run_url> [soubor]
  local _run_url="$1" _file="${2:-$_GH_GOVERNANCE_REPORT_FILE}"
  _gh-governance-report-render --errors-warnings-only "$_file"
  echo ""
  echo "Kompletní report (včetně info položek): $_run_url"
}

_gh-governance-report-open-issue() {
  # Vypíše otevřené reconcile issue (label reconcile-report) jako řádek
  # "<číslo>\t<createdAt>", nebo nic; rc 1 při selhání výpisu.
  # Použití: _gh-governance-report-open-issue
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_GOVERNANCE_REPO || return 1
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue list \
    --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
    --label "$_GH_GOVERNANCE_REPORT_LABEL" --state open \
    --json number,createdAt \
    --jq '.[0] | select(. != null) | [(.number|tostring), .createdAt] | @tsv'
}

_gh-governance-report-issue-age-days() {
  # Vypíše stáří issue v celých dnech od createdAt (ISO 8601 z gh);
  # rc 1 při neparsovatelném datu (volající issue považuje za mladé).
  # Použití: _gh-governance-report-issue-age-days <createdAt>
  local _created_s
  _created_s=$(date -d "$1" +%s 2>/dev/null) || return 1
  echo $(( ( $(date +%s) - _created_s ) / 86400 ))
}

_gh-governance-report-issue-create() {
  # Založí reconcile issue s labelem a závazným titulkem.
  # Použití: _gh-governance-report-issue-create <tělo>
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue create \
    --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
    --label "$_GH_GOVERNANCE_REPORT_LABEL" \
    --title "Reconcile report: zjištění kontroly konzistence" \
    --body "$1" >/dev/null
}

_gh-governance-report-issue-rotate() {
  # Rotace reconcile issue (defs-governance-repo.md, reconcile issue, bod 4):
  # nejdřív zavře staré issue not_planned se závěrečným komentářem, pak založí
  # nové, jehož tělo odkazuje na předchozí (zmínku GitHub ukáže i v timeline
  # starého issue). Pořadí drží invariant „nejvýše jedno otevřené reconcile
  # issue“; selhané založení = rc 1 (workflow červený, nejbližší denní běh
  # s errorem issue založí).
  # Použití: _gh-governance-report-issue-rotate <číslo> <run_url> <tělo>
  local _number="$1" _run_url="$2" _body="$3" _days="$GH_RECONCILE_ISSUE_MAX_AGE_DAYS"
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue close "$_number" \
    --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" --reason "not planned" \
    --comment "Rotace: issue je otevřené déle než $_days dní a zjištění trvají. Zavřeno jako „not planned“; pokračování v novém issue, které zakládá tento běh. $_run_url" \
    >/dev/null || return 1
  _gh-governance-report-issue-create \
    "Pokračování issue #${_number} (rotace po $_days dnech, zjištění trvají).

$_body"
}

_gh-governance-report-issue-sync() {
  # Životní cyklus reconcile issue (závazně: defs/defs-governance-repo.md,
  # sekce „reconcile issue“):
  #   weekly + ≥1 warning/error → založí issue, nebo komentuje otevřené;
  #                               otevřené starší než GH_RECONCILE_ISSUE_MAX_AGE_DAYS
  #                               dní místo komentáře rotuje (zavře not_planned
  #                               s komentářem a založí nové);
  #   weekly + čistý report     → otevřené issue zavře completed se závěrečným
  #                               komentářem (bez ohledu na stáří);
  #   daily  + ≥1 error         → založí issue, jen pokud žádné otevřené není
  #                               (otevřené issue denní běh nekomentuje ani nerotuje);
  #   zavírá výhradně weekly.
  # Použití: _gh-governance-report-issue-sync <daily|weekly> <run_url> [soubor]
  local _mode="$1" _run_url="$2" _file="${3:-$_GH_GOVERNANCE_REPORT_FILE}"
  local _errors _warnings _open _created="" _age _body
  case "$_mode" in
    daily|weekly) ;;
    *) echo "Chyba: Režim musí být daily nebo weekly (je '$_mode')." >&2; return 1 ;;
  esac
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_GOVERNANCE_REPO GH_RECONCILE_ISSUE_MAX_AGE_DAYS || return 1
  if [[ ! "$GH_RECONCILE_ISSUE_MAX_AGE_DAYS" =~ ^[0-9]+$ ]]; then
    echo "Chyba: GH_RECONCILE_ISSUE_MAX_AGE_DAYS musí být celé číslo (je '$GH_RECONCILE_ISSUE_MAX_AGE_DAYS')." >&2
    return 1
  fi
  _errors=$(_gh-governance-report-count error "$_file")
  _warnings=$(_gh-governance-report-count warning "$_file")
  _open=$(_gh-governance-report-open-issue) || return 1
  if [[ "$_open" == *$'\t'* ]]; then
    _created="${_open#*$'\t'}"; _open="${_open%%$'\t'*}"
  fi

  if [[ "$_mode" == weekly ]]; then
    if [[ $(( _errors + _warnings )) -gt 0 ]]; then
      _body=$(_gh-governance-report-issue-body "$_run_url" "$_file")
      if [[ -z "$_open" ]]; then
        _gh-governance-report-issue-create "$_body"
      elif _age=$(_gh-governance-report-issue-age-days "$_created") && \
          (( _age >= GH_RECONCILE_ISSUE_MAX_AGE_DAYS )); then
        _gh-governance-report-issue-rotate "$_open" "$_run_url" "$_body"
      else
        GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue comment "$_open" \
          --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" --body "$_body" >/dev/null
      fi
    elif [[ -n "$_open" ]]; then
      GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue comment "$_open" \
        --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
        --body "Týdenní vyhodnocení: čistý report (bez warningů a errorů). $_run_url" >/dev/null
      GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue close "$_open" \
        --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" --reason completed >/dev/null
    fi
  elif [[ "$_errors" -gt 0 && -z "$_open" ]]; then
    _body=$(_gh-governance-report-issue-body "$_run_url" "$_file")
    _gh-governance-report-issue-create "$_body"
  fi
}
