#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Ukazatel posledního aplikovaného stavu konfigurace (defs/defs.md):
# soubor state/<ghRepoName> v gov
# repu, obsah = jeden řádek s plným SHA commitu gov repa, jehož konfigurace
# byla na repo naposledy úspěšně aplikována. Modul pracuje nad lokálním
# checkoutem gov repa (kořen = rodič adresáře conf.d, viz _GH_COMMON_CONF_D).
# Závislosti: gh-common-defs.sh (_GH_COMMON_CONF_D, _GH_CONF, _require_vars),
# lib/gh-conf.sh (_gh-conf-parse-file, _gh-conf-effective), lib/gh-repository-policy.sh
# (_gh-validate-admin-team, _gh-jenkins-delete, _gh-jenkins-policy-resolve,
#  _gh-repository-policy-live-admin-removal-safe).
[[ -n "${_GH_GOVERNANCE_STATE_LOADED:-}" ]] && \
  declare -F _gh-governance-state-read >/dev/null && return 0
_GH_GOVERNANCE_STATE_LOADED=1

_GH_GOVERNANCE_SHA_REGEX='^[0-9a-f]{40}$'

_gh-governance-checkout-root() {
  # Vypíše kořen lokálního checkoutu gov repa (rodič adresáře conf.d).
  # Použití: _gh-governance-checkout-root
  local _root
  _root="$(dirname "$_GH_COMMON_CONF_D")"
  if ! git -C "$_root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Chyba: '$_root' není git checkout gov repa – ukazatel /state/ vyžaduje checkout (nastav GH_CONFD_ROOT na conf.d checkoutu gov repa)." >&2
    return 1
  fi
  printf '%s\n' "$_root"
}

_gh-governance-run-sha() {
  # Zafixuje (při prvním volání) a vypíše SHA HEAD checkoutu gov repa –
  # celý běh pracuje s jedinou verzí konfigurace (RUN_SHA).
  # Použití: _gh-governance-run-sha
  local _root _sha
  if [[ -z "${_GH_GOVERNANCE_RUN_SHA:-}" ]]; then
    _root=$(_gh-governance-checkout-root) || return 1
    _sha=$(git -C "$_root" rev-parse HEAD 2>/dev/null)
    if ! _gh-match "$_sha" "$_GH_GOVERNANCE_SHA_REGEX"; then
      echo "Chyba: Nepodařilo se zjistit SHA HEAD checkoutu gov repa ('$_sha')." >&2
      return 1
    fi
    _GH_GOVERNANCE_RUN_SHA="$_sha"
  fi
  printf '%s\n' "$_GH_GOVERNANCE_RUN_SHA"
}

_gh-governance-state-read() {
  # Přečte ukazatel state/<ghRepoName> z checkoutu gov repa a vypíše SHA.
  # rc: 0 = OK, 1 = ukazatel neexistuje (adopce), 2 = nevalidní obsah/chyba.
  # Použití: _gh-governance-state-read <ghRepoName>
  local _repo_name="$1" _root _file _sha=""
  _root=$(_gh-governance-checkout-root) || return 2
  _file="$_root/state/$_repo_name"
  [[ -f "$_file" ]] || return 1
  IFS= read -r _sha < "$_file" || true
  _sha="${_sha%$'\r'}"
  if ! _gh-match "$_sha" "$_GH_GOVERNANCE_SHA_REGEX"; then
    echo "Chyba: state/$_repo_name neobsahuje validní SHA commitu (je '$_sha')." >&2
    return 2
  fi
  printf '%s\n' "$_sha"
}

_gh-governance-state-write() {
  # Zapíše ukazatel state/<ghRepoName> do checkoutu gov repa (jen pracovní
  # kopie; commit+push provádí _gh-governance-state-push jednou na konci běhu).
  # Použití: _gh-governance-state-write <ghRepoName> <sha>
  local _repo_name="$1" _sha="$2" _root
  if ! _gh-match "$_sha" "$_GH_GOVERNANCE_SHA_REGEX"; then
    echo "Chyba: Ukazatel pro '$_repo_name' musí být plné SHA commitu (je '$_sha')." >&2
    return 1
  fi
  _root=$(_gh-governance-checkout-root) || return 1
  mkdir -p "$_root/state" || return 1
  printf '%s\n' "$_sha" > "$_root/state/$_repo_name"
}

_gh-governance-state-push() {
  # Commitne všechny změny pod state/ jedním commitem a pushne; při odmítnutí
  # pushe rebase-retry (max 5×). Při konfliktu vyhrává vzdálená verze (-X ours
  # při rebase) – ukazatel smí být „starší", nikdy „novější" než realita;
  # repo dokonverguje příští běh. Sdílený completion manifest ale ztrátu
  # nesnese: je-li načten manifest modul, po každém rebase se evidované úpravy
  # manifestu idempotentně přehrají znovu (replay) a commit doplní. Bez změn
  # nedělá nic. Selhání pushe nevrací už aplikované změny – volající ho
  # reportuje jako error.
  # Použití: _gh-governance-state-push <commit message>
  local _msg="$1" _root _attempt
  _root=$(_gh-governance-checkout-root) || return 1
  [[ -d "$_root/state" ]] || return 0
  git -C "$_root" add -A state/ || return 1
  git -C "$_root" diff --cached --quiet && return 0
  git -C "$_root" commit -m "$_msg" >/dev/null || return 1
  for _attempt in 1 2 3 4 5; do
    git -C "$_root" push >/dev/null 2>&1 && return 0
    if [[ "$_attempt" == 5 ]]; then
      break
    fi
    echo "Varovani: Push ukazatelů /state/ odmítnut (pokus $_attempt/5), zkouším rebase." >&2
    git -C "$_root" pull --rebase -X ours >/dev/null 2>&1 || {
      git -C "$_root" rebase --abort >/dev/null 2>&1
      echo "Chyba: Rebase při pushi ukazatelů /state/ selhal." >&2
      return 1
    }
    if declare -F _gh-governance-manifest-replay >/dev/null; then
      _gh-governance-manifest-replay || {
        echo "Chyba: Replay úprav completion manifestu po rebase selhal." >&2
        return 1
      }
      git -C "$_root" add -A state/ || return 1
      if ! git -C "$_root" diff --cached --quiet; then
        # Rebase mohl náš commit zahodit jako prázdný (HEAD == upstream) –
        # pak replay změny patří do nového commitu, jinak amend toho našeho.
        if [[ "$(git -C "$_root" rev-parse HEAD)" == "$(git -C "$_root" rev-parse '@{u}' 2>/dev/null)" ]]; then
          git -C "$_root" commit -m "$_msg" >/dev/null || return 1
        else
          git -C "$_root" commit --amend --no-edit >/dev/null || return 1
        fi
      fi
    fi
  done
  echo "Chyba: Push ukazatelů /state/ selhal po 5 pokusech." >&2
  return 1
}

_gh-governance-state-remove() {
  # Odstraní ukazatel state/<ghRepoName> z pracovní kopie (zaniklé repo,
  # track-delete); idempotentní. Commit+push dělá _gh-governance-state-push
  # (`git add -A state/` smazání zachytí).
  # Použití: _gh-governance-state-remove <ghRepoName>
  local _repo_name="$1" _root
  _root=$(_gh-governance-checkout-root) || return 1
  rm -f "$_root/state/$_repo_name"
}

_gh-governance-conf-file-at-commit() {
  # Načte jeden soubor conf.d ve verzi daného commitu gov repa do _GH_CONF pod
  # izolovaný namespace "at-<sha>" (klíče at-<sha>/<název>/<pole>). Starou
  # verzi čte přes `git show` a parsuje reuse _gh-conf-parse-file (žádný
  # druhý parser); dřívější klíče téhož názvu v namespace nejdřív smaže
  # (přes index _GH_CONF_KEYS — jen klíče toho souboru, ne průchod _GH_CONF).
  # rc: 0 = načteno, 1 = soubor v té verzi neexistuje, 2 = chyba (git/parsování).
  # Použití: _gh-governance-conf-file-at-commit <sha> <cesta pod conf.d> <název>
  local _sha="$1" _rel="$2" _name="$3" _root _content _tmp _k
  local -a _errs=()
  _root=$(_gh-governance-checkout-root) || return 2
  _content=$(git -C "$_root" show "$_sha:conf.d/$_rel" 2>/dev/null) || return 1
  _tmp=$(mktemp) || return 2
  printf '%s\n' "$_content" > "$_tmp"
  for _k in ${_GH_CONF_KEYS[at-$_sha/$_name]:-}; do
    unset "_GH_CONF[at-$_sha/$_name/$_k]"
  done
  unset "_GH_CONF_KEYS[at-$_sha/$_name]"
  _gh-conf-parse-file "$_tmp" "$_rel@$_sha" "at-$_sha" "$_name" _errs
  rm -f "$_tmp"
  if [[ ${#_errs[@]} -gt 0 ]]; then
    printf '%s\n' "${_errs[@]}" >&2
    echo "Chyba: Konfiguraci $_rel ve verzi $_sha nelze naparsovat." >&2
    return 2
  fi
  return 0
}

_gh-governance-conf-project-at-commit() {
  # Načte projects/<projectKey>.conf ve verzi commitu (klíče
  # at-<sha>/projects/<projectKey>/<pole> — stejný tvar jako živá konfigurace,
  # aby _gh-conf-effective fungovala s prefixem namespace). rc 0 = načteno,
  # 1 = soubor v té verzi neexistuje, 2 = chyba.
  # Použití: _gh-governance-conf-project-at-commit <sha> <projectKey>
  _gh-governance-conf-file-at-commit "$1" "projects/$2.conf" "projects/$2"
}

_gh-governance-conf-repo-at-commit() {
  # Načte nastavení repa projects/<projectKey>/<ghName>.conf ve verzi commitu
  # (klíče at-<sha>/repos/<projectKey>/<ghName>/<pole>). rc 1 = soubor v té
  # verzi neexistuje → platila konfigurace projektu. rc 2 = chyba.
  # Použití: _gh-governance-conf-repo-at-commit <sha> <projectKey> <ghName>
  _gh-governance-conf-file-at-commit "$1" "projects/$2/$3.conf" "repos/$2/$3"
}

_gh-governance-conf-effective-at-commit() {
  # Načte projekt i nastavení repa ve verzi commitu (prázdný <ghName> = jen
  # projekt) a naplní nameref efektivní hodnotou pole přes _gh-conf-effective
  # s namespace at-<sha>. Soubory v dané verzi nemusí existovat → hodnota
  # prázdná (rc 0). rc 1 = chyba (git/parsování) – volající nesmí nic měnit.
  # Použití: _gh-governance-conf-effective-at-commit <sha> <projectKey> <ghName> <pole> <out_ref>
  local _sha="$1" _key="$2" _gh_name="$3" _field="$4"
  declare -n _ceac_ref="$5"
  _ceac_ref=""
  _gh-governance-conf-project-at-commit "$_sha" "$_key"
  [[ $? -ne 2 ]] || return 1
  if [[ -n "$_gh_name" ]]; then
    _gh-governance-conf-repo-at-commit "$_sha" "$_key" "$_gh_name"
    [[ $? -ne 2 ]] || return 1
  fi
  _gh-conf-effective "$_key" "$_gh_name" "$_field" "$5" "at-$_sha"
  return 0
}

_gh-governance-conf-domain-at-commit() {
  # Vypíše klíč domain projektu ve verzi commitu (prázdné = projekt v té
  # verzi neexistoval). rc 0 = OK, 2 = chyba (git/parsování).
  # Použití: _gh-governance-conf-domain-at-commit <sha> <projectKey>
  local _sha="$1" _key="$2"
  _gh-governance-conf-project-at-commit "$_sha" "$_key"
  case $? in
    0) printf '%s\n' "${_GH_CONF[at-$_sha/projects/$_key/domain]:-}" ;;
    1) ;;
    *) return 2 ;;
  esac
  return 0
}

_gh-governance-conf-jenkins-at-commit() {
  # Vypíše jenkins_user domény projektu ve verzi commitu (prázdné = projekt
  # nebo doména v té verzi neexistovaly, nebo doména login nemá).
  # rc 0 = OK, 2 = chyba (git/parsování).
  # Použití: _gh-governance-conf-jenkins-at-commit <sha> <projectKey>
  local _sha="$1" _key="$2" _domain
  _domain=$(_gh-governance-conf-domain-at-commit "$_sha" "$_key") || return 2
  [[ -n "$_domain" ]] || return 0
  _gh-governance-conf-file-at-commit "$_sha" "domains/$_domain.conf" "domains/$_domain"
  case $? in
    0) printf '%s\n' "${_GH_CONF[at-$_sha/domains/$_domain/jenkins_user]:-}" ;;
    1) ;;
    *) return 2 ;;
  esac
  return 0
}

_gh-governance-jenkins-to-remove-between() {
  # Naplní nameref Jenkins loginem k odebrání: login domény projektu oldKey
  # na SHA old_sha, pokud se liší od loginu domény projektu newKey na SHA
  # new_sha. Jednoklíčové volání (oldKey == newKey) pokrývá přesun projektu
  # do jiné domény i výměnu jenkins_user; dvouklíčové přesun repa mezi
  # projekty (move-repository). Pojistky: nikdy login aktuální domény
  # projektu newKey (_GH_CONF) ani governance bota. Porovnání
  # case-insensitive (GitHub loginy). rc 1 = chyba – volající nesmí odebírat.
  # Použití: local _l; _gh-governance-jenkins-to-remove-between <oldKey> <old_sha> <newKey> <new_sha> _l
  local _old_key="$1" _old_sha="$2" _new_key="$3" _new_sha="$4"
  local _old _new _current _configured _decision
  declare -n _rm_login_ref="$5"
  _rm_login_ref=""
  _old=$(_gh-governance-conf-jenkins-at-commit "$_old_sha" "$_old_key") || return 1
  _new=$(_gh-governance-conf-jenkins-at-commit "$_new_sha" "$_new_key") || return 1
  [[ -n "$_old" ]] || return 0
  [[ "${_old,,}" != "${_new,,}" ]] || return 0
  # Jen login aktuální domény (nezávisí na nastavení repa) — bez ghName.
  _gh-jenkins-policy-resolve "$_new_key" "" _current _configured _decision || return 1
  [[ "${_old,,}" != "${_current,,}" ]] || return 0
  [[ "${_old,,}" != "${GH_GOVERNANCE_BOT_USER,,}" ]] || return 0
  _rm_login_ref="$_old"
  return 0
}

_gh-governance-jenkins-to-remove() {
  # Jednoklíčová zkratka _gh-governance-jenkins-to-remove-between (diff
  # ukazatel→RUN_SHA v rámci téhož projektu).
  # Použití: local _l; _gh-governance-jenkins-to-remove <projectKey> <pointer_sha> <run_sha> _l
  _gh-governance-jenkins-to-remove-between "$1" "$2" "$1" "$3" "$4"
}

_gh-governance-webhook-urls-to-remove() {
  # Naplní nameref pole URL spravovaného webhooku k odebrání (defs/defs.md,
  # webhook repa): efektivní webhook_url repa na SHA ukazatele **a v každé
  # verzi konfigurace mezi ukazatelem a RUN_SHA** (commity pointer..run_sha
  # dotýkající se souboru projektu nebo nastavení repa), které se liší od
  # efektivní URL na RUN_SHA. Průchod historií je nutný: workflow repo-sync
  # hooky mění hned po každém merge, ale ukazatel neposouvá — mezi dvěma
  # posuny ukazatele tak může vzniknout a zase zaniknout URL, kterou by diff
  # dvou bodů neznal (ověřeno v pískovišti 2026-09-24: osiřelý hook).
  # Pojistka: URL z aktuálně načtené efektivní konfigurace (_GH_CONF) se
  # nikdy neodebírá. Prázdné pole = nic. rc 1 = chyba (git/parsování) –
  # volající nesmí odebírat.
  # Použití: local -a _u=(); _gh-governance-webhook-urls-to-remove <projectKey> <ghName> <pointer_sha> <run_sha> _u
  local _key="$1" _gh_name="$2" _pointer_sha="$3" _run_sha="$4"
  local _root _sha _url _new="" _current="" _shas
  local -A _seen=()
  local -a _paths=("conf.d/projects/$_key.conf")
  declare -n _rm_urls_ref="$5"
  _rm_urls_ref=()
  [[ -n "$_gh_name" ]] && _paths+=("conf.d/projects/$_key/$_gh_name.conf")
  _root=$(_gh-governance-checkout-root) || return 1
  _shas=$(git -C "$_root" rev-list "${_pointer_sha}..${_run_sha}" -- "${_paths[@]}") || return 1
  _gh-governance-conf-effective-at-commit "$_run_sha" "$_key" "$_gh_name" webhook_url _new \
    || return 1
  _gh-conf-effective "$_key" "$_gh_name" webhook_url _current
  for _sha in "$_pointer_sha" $_shas; do
    [[ "$_sha" == "$_run_sha" ]] && continue
    _gh-governance-conf-effective-at-commit "$_sha" "$_key" "$_gh_name" webhook_url _url \
      || return 1
    [[ -n "$_url" && "$_url" != "$_new" && "$_url" != "$_current" ]] || continue
    [[ -v _seen["$_url"] ]] && continue
    _seen["$_url"]=1
    _rm_urls_ref+=("$_url")
  done
  return 0
}

_gh-governance-conf-teams-at-commit() {
  # Naplní nameref pole slugy efektivních týmů repa (repository_teams projektu
  # + repository_teams_add nastavení repa; prázdný <ghName> = jen projekt) ve
  # verzi konfigurace daného commitu gov repa. Soubory v dané verzi nemusí
  # existovat → prázdný seznam (rc 0).
  # rc: 0 = OK, 1 = chyba (git/parsování) – volající nesmí nic odebírat.
  # Použití: local -a _t=(); _gh-governance-conf-teams-at-commit <sha> <projectKey> <ghName> _t
  local _sha="$1" _key="$2" _gh_name="$3" _rest="" _item
  declare -n _teams_ref="$4"
  _teams_ref=()
  _gh-governance-conf-effective-at-commit "$_sha" "$_key" "$_gh_name" repository_teams _rest \
    || return 1
  _rest+=","
  while [[ "$_rest" == *,* ]]; do
    _item="${_rest%%,*}"
    _rest="${_rest#*,}"
    [[ -n "$_item" ]] && _teams_ref+=("${_item%%|*}")
  done
  return 0
}

_gh-governance-teams-to-remove-between() {
  # Naplní nameref pole týmy k odebrání: {efektivní týmy repa oldKey/oldGhName
  # na SHA old_sha} − {efektivní týmy repa newKey/newGhName na SHA new_sha}
  # (defs/defs-governance-repo.md, diff ukazatele). Jednoklíčové volání
  # (oldKey == newKey, týž ghName) je diff ukazatel→RUN_SHA v rámci projektu;
  # dvouklíčové přesun repa mezi projekty (move-repository).
  # Pojistka: tým z aktuálně načtené efektivní konfigurace repa
  # newKey/newGhName (_GH_CONF) se do seznamu nikdy nedostane.
  # Použití: local -a _rm=(); _gh-governance-teams-to-remove-between <oldKey> <old_sha> <oldGhName> <newKey> <new_sha> <newGhName> _rm
  local _old_key="$1" _old_sha="$2" _old_gh_name="$3"
  local _new_key="$4" _new_sha="$5" _new_gh_name="$6"
  local _team _new_csv _current=""
  declare -n _rm_ref="$7"
  local -a _old_teams=() _new_teams=()
  _rm_ref=()
  _gh-governance-conf-teams-at-commit "$_old_sha" "$_old_key" "$_old_gh_name" _old_teams || return 1
  _gh-governance-conf-teams-at-commit "$_new_sha" "$_new_key" "$_new_gh_name" _new_teams || return 1
  _new_csv=",$(IFS=,; echo "${_new_teams[*]-}"),"
  _gh-conf-effective "$_new_key" "$_new_gh_name" repository_teams _current
  _current=",$_current,"
  for _team in "${_old_teams[@]}"; do
    # ghOrgSecurityManagersTeam se nikdy neodebírá (implicitní součást politiky;
    # v historické konfiguraci se mohl vyskytnout před zákazem v repository_teams).
    [[ "$_team" == "$GH_SECURITY_MANAGERS_TEAM" ]] && continue
    [[ "$_new_csv" == *",$_team,"* ]] && continue
    [[ "$_current" == *",$_team|"* ]] && continue
    _rm_ref+=("$_team")
  done
  return 0
}

_gh-governance-teams-to-remove() {
  # Jednoklíčová zkratka _gh-governance-teams-to-remove-between (diff
  # ukazatel→RUN_SHA v rámci téhož projektu a repa).
  # Použití: local -a _rm=(); _gh-governance-teams-to-remove <projectKey> <ghName> <pointer_sha> <run_sha> _rm
  _gh-governance-teams-to-remove-between "$1" "$3" "$2" "$1" "$4" "$2" "$5"
}

_gh-governance-teams-remove() {
  # Odebere z repa týmy z nameref pole (volat až po úspěšném kompletním
  # assignu politiky). Pojistky: tým z aktuální efektivní konfigurace repa
  # (repository_teams projektu + repository_teams_add) se nikdy neodebírá;
  # před odebráním týmu s živým admin právem ověří, že na repu zůstává jiný
  # admin tým; DELETE 404-tolerantně. Odebrané týmy vypisuje po řádcích na
  # stdout (podklad pro report).
  # Použití: _gh-governance-teams-remove <repo_path> <projectKey> <ghName> <teams_array_name>
  local _repo_path="$1" _key="$2" _gh_name="$3" _team _permission _observed _current=""
  declare -n _rm_teams_ref="$4"
  local -A _live=()
  [[ ${#_rm_teams_ref[@]} -gt 0 ]] || return 0
  _gh-validate-admin-team "$_key" GITHUB_REPO_TEAMS || return 1
  _require_vars GITHUB_ORG GITHUB_ORG_HOSTNAME || return 1
  _observed=$(GH_HOST="$GITHUB_ORG_HOSTNAME" gh api "repos/$_repo_path/teams" \
    --paginate --jq '.[] | [.slug, .permission] | @tsv') || return 1
  while IFS=$'\t' read -r _team _permission; do
    [[ -n "$_team" ]] && _live["$_team"]="$_permission"
  done <<< "$_observed"
  _gh-conf-effective "$_key" "$_gh_name" repository_teams _current
  _current=",$_current,"
  for _team in "${_rm_teams_ref[@]}"; do
    [[ "$_current" == *",$_team|"* ]] && continue
    [[ -v _live["$_team"] ]] || continue
    if [[ "${_live[$_team]}" == admin ]]; then
      if ! _gh-repository-policy-live-admin-removal-safe "$_repo_path" "$_team"; then
        echo "Chyba: Tým '$_team' je jediný admin tým repa '$_repo_path' – neodebírám." >&2
        return 1
      fi
    fi
    _gh-jenkins-delete "orgs/$GITHUB_ORG/teams/$_team/repos/$_repo_path" "$_key" || return 1
    printf '%s\n' "$_team"
  done
  return 0
}
