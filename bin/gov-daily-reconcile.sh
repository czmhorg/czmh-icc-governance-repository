#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Entry skript workflow daily-reconcile; spustitelný i lokálně nad checkoutem
# gov repa. Report renderuje do $GITHUB_STEP_SUMMARY (v Actions), jinak na
# stdout; životní cyklus reconcile issue řeší jen v Actions.

_gov_show_help() {
  echo "Syntaxe: gov-daily-reconcile.sh [--mode auto|daily|weekly] [--report SOUBOR]"
  echo "Účel:    Kontrola konzistence rep organizace (defs/defs.md): klasifikace"
  echo "         rep, konvergence spravovaných nearchivovaných rep, odebírání"
  echo "         týmů dle ukazatele /state/, počty rep projektů, report a"
  echo "         životní cyklus reconcile issue."
  echo ""
  echo "Volby:"
  echo "  --mode REŽIM     auto (výchozí; pondělí UTC = weekly, jinak daily),"
  echo "                   daily nebo weekly (weekly navíc zavírá čisté issue)."
  echo "  --report SOUBOR  Kam zapsat TSV itemy reportu (výchozí: mktemp)."
  echo ""
  echo "Příklad: bash governance/bin/gov-daily-reconcile.sh --mode daily"
  echo ""
  echo "Práva:   admin v organizaci (čtení rep, týmy, rulesety), push do gov repa (/state/),"
  echo "         issues RW na gov repu (reconcile issue)."
}

_gov_mode=auto
_gov_report=""
_gov_expect=""
for _a in "$@"; do
  if [[ -n "$_gov_expect" ]]; then
    case "$_gov_expect" in
      mode)   _gov_mode="$_a" ;;
      report) _gov_report="$_a" ;;
    esac
    _gov_expect=""
    continue
  fi
  case "$_a" in
    --help)   _gov_show_help; exit 0 ;;
    --mode)   _gov_expect=mode ;;
    --report) _gov_expect=report ;;
    *) echo "Chyba: Neznámý argument '$_a' (viz --help)." >&2; exit 1 ;;
  esac
done
if [[ -n "$_gov_expect" ]]; then
  echo "Chyba: Volba --$_gov_expect vyžaduje hodnotu." >&2
  exit 1
fi
case "$_gov_mode" in
  auto|daily|weekly) ;;
  *) echo "Chyba: --mode musí být auto, daily nebo weekly (je '$_gov_mode')." >&2; exit 1 ;;
esac

source "$(dirname "${BASH_SOURCE[0]}")/gov-env.sh"

# Pondělí pozná skript, ne cron (jediný denní cron, viz plán PoC).
if [[ "$_gov_mode" == auto ]]; then
  if [[ "$(date -u +%u)" == 1 ]]; then
    _gov_mode=weekly
  else
    _gov_mode=daily
  fi
fi
echo "Režim vyhodnocení: $_gov_mode"

[[ -n "$_gov_report" ]] || _gov_report=$(mktemp) || exit 1
_gh-governance-report-init "$_gov_report"
_gh-governance-reconcile-run || exit 1

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  _gh-governance-report-render "$_gov_report" >> "$GITHUB_STEP_SUMMARY"
else
  _gh-governance-report-render "$_gov_report"
fi

if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  _gov_run_url="${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  _gh-governance-report-issue-sync "$_gov_mode" "$_gov_run_url" "$_gov_report" || exit 1
fi
exit 0
