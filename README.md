<!-- GENEROVANO gov-sync.sh -- needitovat v gov repu -->
# Governance repository

Tento repozitář je řídicím centrem projektu **správy GitHub repozitářů
a migrace z Bitbucket Serveru** v této organizaci.

## Co projekt řeší

Organizace obsahuje tisíce repozitářů rozdělených do projektů. Tento projekt
zajišťuje, aby všechny spravované repozitáře měly jednotné a hlídané
nastavení, aniž by cokoli musel kdokoli nastavovat ručně:

- **Jednotná pravidla** — každý spravovaný repozitář dostává týmy a jejich
  práva, ochranu větví (rulesety `mh-policy-*`), povinné custom properties
  a topic projektu (`ghp-<projekt>`) podle konfigurace v tomto repu.
- **Životní cyklus repozitářů** — založení, archivaci, obnovení nebo přesun
  repozitáře provádí automatika tohoto repa na základě žádosti (issue);
  uživatelé žádosti podávají pohodlně funkcemi `gh-*` (viz níže).
- **Denní kontrola konzistence (reconcile)** — automatika denně porovnává
  skutečný stav repozitářů s konfigurací, drift opravuje a odchylky hlásí
  v issue `reconcile-report`.
- **Migrace z Bitbucketu** — repozitáře se z Bitbucket Serveru přenášejí
  nástroji `bb-*` podle jmenné konvence `czmh-icc-<projekt>-<jméno>`
  a rovnou podléhají výše uvedeným pravidlům.

## Co je v tomto repozitáři

- `conf.d/` — **jediné místo pravdy** konfigurace: projekty, business
  services, domény a profily ochrany větví; mění se výhradně pull requestem,
- `state/` — stavové soubory automatiky; zapisuje výhradně governance bot,
- `splits/` — mapy hromadného rozdělení projektů (schvalované pull requestem),
- `.github/workflows/`, `bin/`, `lib/` — kód automatiky; nasazuje se sem
  z vývojového repozitáře a v tomto repu se needituje (soubory nesou
  hlavičku `GENEROVANO`).

## Další informace

Skripty `gh-*` a `bb-*`, návod k instalaci a podrobná dokumentace jsou
v repozitáři [`czmh-icc-gh-bash-toolkit`](../../../czmh-icc-gh-bash-toolkit).
