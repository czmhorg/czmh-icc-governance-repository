#!/bin/bash
# GENEROVANO gov-sync.sh -- needitovat v gov repu

# Pracovní repa funkcí (docs/navrh/pracovni-repa-funkci.md): trvalé klony
# v ${GH_WORK_REPOS_ROOT}, se kterými pracují výhradně funkce (pracovní klon
# gov repa, pracovní klony řídicích rep migrace). Modul poskytuje zámek per
# pracovní repo a sync (clone/pull) bez uložení tokenu do .git/config.
# Selhání git operace se nikdy neopravuje automaticky (žádné delete +
# reclone) — _gh-work-repo-error vypíše akční hlášku pro ruční zásah.
# Pořadí práce s pracovním repem: zámek → sync → práce → uvolnění zámku.
# Závislosti: git; GH_WORK_REPOS_ROOT definuje gh-common-defs.sh.
[[ -n "${_GH_WORK_REPO_LOADED:-}" ]] && \
  declare -F _gh-work-repo-sync >/dev/null && return 0
_GH_WORK_REPO_LOADED=1

# Timeout čekání na obsazený zámek v sekundách (testy hodnotu snižují).
: "${_GH_WORK_LOCK_TIMEOUT_S:=30}"

_gh-work-repos-root() {
  # Vypíše kořen pracovních rep funkcí.
  # Použití: _gh-work-repos-root
  printf '%s\n' "${GH_WORK_REPOS_ROOT:-${HOME}/.local/state/gh-work}"
}

_gh-work-repo-lock() {
  # Zamkne pracovní repo (mkdir je atomický); zámek <repo_dir>.lock se drží po
  # celou práci s klonem. Obsazený zámek živým procesem → čekání max
  # _GH_WORK_LOCK_TIMEOUT_S s (à 1 s), po timeoutu akční chyba. Osiřelý zámek
  # (uložený PID už neběží) se převezme — jediná povolená automatika; čas
  # v zámku je jen diagnostika pro člověka.
  # Použití: _gh-work-repo-lock <repo_dir>
  local _dir="$1" _lock="$1.lock" _pid _since _waited=0
  mkdir -p "$(dirname "$_lock")" || return 1
  while :; do
    if mkdir "$_lock" 2>/dev/null; then
      printf '%s\n%s\n' $$ "$(date '+%Y-%m-%d %H:%M:%S')" > "$_lock/pid"
      return 0
    fi
    _pid="" _since=""
    { read -r _pid; read -r _since; } < "$_lock/pid" 2>/dev/null
    if [[ -n "$_pid" ]] && ! kill -0 "$_pid" 2>/dev/null; then
      rm -rf "$_lock"
      continue
    fi
    if (( _waited >= _GH_WORK_LOCK_TIMEOUT_S )); then
      echo "Chyba: Pracovní repo '$_dir' je zamčené jiným během (PID ${_pid:-neznámý}, od ${_since:-neznámo}, zámek '$_lock')." >&2
      echo "Počkej na doběhnutí procesu ${_pid:-}; pokud už neběží, smaž adresář zámku: rm -rf '$_lock'" >&2
      return 1
    fi
    sleep 1
    _waited=$(( _waited + 1 ))
  done
}

_gh-work-repo-unlock() {
  # Uvolní zámek pracovního repa.
  # Použití: _gh-work-repo-unlock <repo_dir>
  rm -rf "$1.lock"
}

_gh-work-repo-error() {
  # Akční hláška po selhání git operace v pracovním repu; opravu (typicky
  # delete + reclone) provádí vždy člověk. Vrací 1, aby šla použít přímo
  # v návratové cestě volajícího.
  # Použití: _gh-work-repo-error <repo_dir> <operace> <detail/výstup gitu>
  echo "Chyba: Git operace '$2' v pracovním repu '$1' selhala." >&2
  [[ -n "$3" ]] && printf '%s\n' "$3" >&2
  echo "Zkontroluj 'git -C \"$1\" status'; pokud v repu nejsou rozpracované změny, můžeš adresář smazat a funkce si ho příště naclonuje znovu." >&2
  return 1
}

_gh-work-repo-clone() {
  # První naklonování pracovního repa. Bez <auth_url> plain clone (credential
  # helper); s <auth_url> init + remote origin = <plain_url> + fetch
  # tokenizovanou URL pouze jako argumentem (token nezůstává v .git/config;
  # chybový výstup fetche se zahazuje — může obsahovat token). Nedokončený
  # klon se maže — repo před během neexistovalo, nejde o uživatelská data.
  # Použití: _gh-work-repo-clone <repo_dir> <plain_url> [<branch> <auth_url>]
  local _dir="$1" _url="$2" _branch="${3:-}" _auth_url="${4:-}" _out=""
  if [[ -z "$_auth_url" ]]; then
    _out=$(git clone --quiet "$_url" "$_dir" 2>&1) && return 0
    rm -rf "$_dir"
    _gh-work-repo-error "$_dir" "clone" "$_out"
    return 1
  fi
  if _out=$(git init -q "$_dir" 2>&1) \
    && _out=$(git -C "$_dir" remote add origin "$_url" 2>&1) \
    && git -C "$_dir" fetch -q "$_auth_url" \
         "+refs/heads/${_branch}:refs/remotes/origin/${_branch}" 2>/dev/null \
    && _out=$(git -C "$_dir" checkout -q -b "$_branch" "origin/$_branch" 2>&1); then
    return 0
  fi
  rm -rf "$_dir"
  _gh-work-repo-error "$_dir" "clone (init + fetch)" "$_out"
  return 1
}

_gh-work-repo-update() {
  # Aktualizace existujícího pracovního repa. Před fetchem ověří, že jde
  # o git repo s očekávaným origin, čistým pracovním stromem a bez
  # nepushnutých commitů (ff-only pull by je tiše přešel a příští push
  # propašoval) — cokoli z toho je stav pro ruční zásah.
  # Použití: _gh-work-repo-update <repo_dir> <plain_url> [<branch> <auth_url>]
  local _dir="$1" _url="$2" _branch="${3:-}" _auth_url="${4:-}" _out _upstream
  if ! git -C "$_dir" rev-parse --git-dir >/dev/null 2>&1; then
    _gh-work-repo-error "$_dir" "kontrola repa" "adresář existuje, ale není git repo"
    return 1
  fi
  _out=$(git -C "$_dir" remote get-url origin 2>&1)
  if [[ "$_out" != "$_url" ]]; then
    _gh-work-repo-error "$_dir" "kontrola remote" "origin URL '$_out' neodpovídá očekávané '$_url'"
    return 1
  fi
  _out=$(git -C "$_dir" status --porcelain 2>&1) || {
    _gh-work-repo-error "$_dir" "status" "$_out"; return 1; }
  if [[ -n "$_out" ]]; then
    _gh-work-repo-error "$_dir" "kontrola čistoty" "pracovní strom obsahuje rozpracované změny:"$'\n'"$_out"
    return 1
  fi
  [[ -n "$_branch" ]] && _upstream="origin/$_branch" || _upstream="@{u}"
  _out=$(git -C "$_dir" rev-list --count "$_upstream..HEAD" 2>&1)
  if [[ "$_out" != "0" ]]; then
    _gh-work-repo-error "$_dir" "kontrola nepushnutých commitů" "commity nad ${_upstream}: $_out"
    return 1
  fi
  if [[ -n "$_auth_url" ]]; then
    if ! git -C "$_dir" fetch -q "$_auth_url" \
         "+refs/heads/${_branch}:refs/remotes/origin/${_branch}" 2>/dev/null; then
      _gh-work-repo-error "$_dir" "fetch" "výstup gitu se zahazuje (URL obsahuje token)"
      return 1
    fi
    _out=$(git -C "$_dir" merge --ff-only --quiet "refs/remotes/origin/$_branch" 2>&1) || {
      _gh-work-repo-error "$_dir" "merge --ff-only" "$_out"; return 1; }
  else
    _out=$(git -C "$_dir" pull --ff-only --quiet 2>&1) || {
      _gh-work-repo-error "$_dir" "pull --ff-only" "$_out"; return 1; }
  fi
  return 0
}

_gh-work-repo-sync() {
  # Synchronizuje pracovní repo (životní cyklus dle návrhu): neexistuje →
  # clone, existuje → aktualizace ff-only pullem. Volá se pod zámkem
  # (_gh-work-repo-lock). S <auth_url> (BB: user:token v URL) se tokenizovaná
  # URL používá výhradně jako argument fetche — v .git/config zůstává jen
  # <plain_url>.
  # Použití: _gh-work-repo-sync <repo_dir> <plain_url> [<branch> <auth_url>]
  local _dir="$1"
  if [[ ! -d "$_dir" ]]; then
    _gh-work-repo-clone "$@"
  else
    _gh-work-repo-update "$@"
  fi
}
