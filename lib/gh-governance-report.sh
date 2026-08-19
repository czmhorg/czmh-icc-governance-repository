#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Report kontroly konzistence (reconcile) a životní cyklus reconcile issue
# dle závazného postupu v defs/defs.md.
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
  # Vypíše číslo otevřeného reconcile issue (label reconcile-report), nebo nic.
  # Použití: _gh-governance-report-open-issue
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_GOVERNANCE_REPO || return 1
  GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue list \
    --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
    --label "$_GH_GOVERNANCE_REPORT_LABEL" --state open \
    --json number --jq '.[0].number // empty'
}

_gh-governance-report-issue-sync() {
  # Životní cyklus reconcile issue (governance-repo.md ř. 160–165):
  #   weekly + ≥1 warning/error → založí issue, nebo komentuje otevřené;
  #   weekly + čistý report     → otevřené issue zavře se závěrečným komentářem;
  #   daily  + ≥1 error         → založí issue, jen pokud žádné otevřené není
  #                               (otevřené issue denní běh nekomentuje);
  #   zavírá výhradně weekly.
  # Použití: _gh-governance-report-issue-sync <daily|weekly> <run_url> [soubor]
  local _mode="$1" _run_url="$2" _file="${3:-$_GH_GOVERNANCE_REPORT_FILE}"
  local _errors _warnings _open _body
  case "$_mode" in
    daily|weekly) ;;
    *) echo "Chyba: Režim musí být daily nebo weekly (je '$_mode')." >&2; return 1 ;;
  esac
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME GH_GOVERNANCE_REPO || return 1
  _errors=$(_gh-governance-report-count error "$_file")
  _warnings=$(_gh-governance-report-count warning "$_file")
  _open=$(_gh-governance-report-open-issue) || return 1

  if [[ "$_mode" == weekly ]]; then
    if [[ $(( _errors + _warnings )) -gt 0 ]]; then
      _body=$(_gh-governance-report-issue-body "$_run_url" "$_file")
      if [[ -n "$_open" ]]; then
        GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue comment "$_open" \
          --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" --body "$_body" >/dev/null
      else
        GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue create \
          --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
          --label "$_GH_GOVERNANCE_REPORT_LABEL" \
          --title "Reconcile report: zjištění kontroly konzistence" \
          --body "$_body" >/dev/null
      fi
    elif [[ -n "$_open" ]]; then
      GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue comment "$_open" \
        --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
        --body "Týdenní vyhodnocení: čistý report (bez warningů a errorů). $_run_url" >/dev/null
      GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue close "$_open" \
        --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" --reason completed >/dev/null
    fi
  else
    if [[ "$_errors" -gt 0 && -z "$_open" ]]; then
      _body=$(_gh-governance-report-issue-body "$_run_url" "$_file")
      GH_HOST="$GITHUB_ORG_HOSTNAME" gh issue create \
        --repo "$GITHUB_ORG/$GH_GOVERNANCE_REPO" \
        --label "$_GH_GOVERNANCE_REPORT_LABEL" \
        --title "Reconcile report: zjištění kontroly konzistence" \
        --body "$_body" >/dev/null
    fi
  fi
}
