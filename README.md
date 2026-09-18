# Ralph

Resuelve issues de GitHub sin supervisión, con dos agentes y un gate real:

```
Codex (gpt-5.6-luna, xhigh)  implementa con la skill tdd  →  abre PR
Claude (opus)                revisa el PR                 →  PASS ? merge : comentarios
Codex                        corrige sobre la misma rama  →  Claude vuelve a revisar
```

**Nada se mergea sin un `<verdict>PASS</verdict>` explícito de Claude.** Si tras
3 rondas de revisión el PR sigue sin pasar, queda abierto y etiquetado
`ralph-needs-human`: el loop nunca mergea por cansancio, y no vuelve a tocar ese
PR en corridas posteriores.

El exit code real de cada agente se conserva antes de pasar su salida por `tee`:
un agente que termina con error nunca puede convertirse en PASS. El veredicto se
acepta únicamente cuando es la última línea de la salida final de Claude; un
fallo de `tee` devuelve 70 y detiene la corrida.

## Es agnóstico al proyecto

Instalá una release etiquetada como `ralph/` en cualquier repo con remoto de
GitHub y funciona (ver [Distribución y versión](#distribución-y-versión)). No
asume lenguaje, framework ni test runner: los agentes deducen los comandos de test,
lint y tipos leyendo `AGENTS.md`, `CLAUDE.md`, `README`, `CONTRIBUTING.md` y el
manifest del proyecto (`Makefile`, `package.json`, `pyproject.toml`,
`Cargo.toml`, `go.mod`, `.github/workflows/`…). Si esos archivos y el manifest
discrepan, mandan las instrucciones de agente.

## Uso

```bash
./ralph/once.sh                                  # base = trunk del repo (main/master)
RALPH_BASE_BRANCH=develop ./ralph/once.sh        # base explícita
RALPH_MAX_ROUNDS=2 ./ralph/once.sh               # menos rondas, menos gasto
RALPH_DRY_RUN=1 ./ralph/once.sh                  # plan de solo lectura
```

La base **nunca** es la rama en la que estés parado: es el trunk del repo,
detectado con `gh repo view` (`main` o `master`, según el repo). Ahí
se mergea cada PR aprobado, y de ahí sale la rama del siguiente issue.

`RALPH_DRY_RUN=1` imprime el plan del selector —prioridad, host, padres,
blockers, exclusión por revisión humana y PR existente— y termina antes de
checkout, agentes, labels, push o merge. Sirve para inspeccionar una corrida
sin modificar el repositorio ni GitHub.

Requisitos para una corrida completa: `git`, `gh` (autenticado, scope `repo`),
`codex`, `claude`, remoto `origin`, y **working tree limpio** — el script salta
entre ramas y mergea. El dry-run sólo necesita las herramientas de lectura
(`git` y `gh`).

## Cómo elige los issues

1. Issues abiertos con el label `ready-for-agent`, **por número ascendente**.
2. Excluye los **épicos**: cualquier issue referenciado por otro bajo `## Parent`.
3. Respeta dependencias: salta los que tienen blockers abiertos bajo
   `## Blocked by`. El estado de cada blocker se consulta **en el momento de
   evaluarlo**, no del listado cacheado al inicio de la pasada: la API de GitHub
   es eventualmente consistente y justo tras cerrar un issue todavía lo devuelve
   abierto, bloqueando de mentira a sus dependientes. Consultarlo en vivo además
   los desbloquea dentro de la misma pasada (por eso el merge a la base ocurre
   antes de seguir: los dependientes heredan el código).

## Orden de prioridad

El orden por defecto es el número de issue, que rara vez coincide con la
prioridad. `RALPH_ISSUE_ORDER` lo fija sin tocar los issues:

```bash
RALPH_ISSUE_ORDER="127 124 126 128" ./ralph/once.sh
```

Esos van primero y en ese orden; el resto detrás, por número. Un número que no
esté abierto y etiquetado se ignora sin ruido: la lista **ordena** el trabajo,
nunca lo **crea**. Y no salta dependencias — un issue con blockers abiertos se
sigue posponiendo aunque encabece la lista.

Es lo que hay que usar para encadenar varias slices sin intervenir. La
alternativa —inventar `## Blocked by` entre issues que no dependen entre sí—
convierte un campo que significa "esto necesita ese código" en un campo de
prioridad, y luego nadie sabe cuál de las dos cosas quiso decir.

El formato esperado en el cuerpo del issue:

```markdown
## Parent
#25

## Blocked by
- #26
- #28
```

## Idempotencia

Si una corrida se corta (Ctrl-C, tope de uso, caída), la siguiente **reutiliza**
la rama y el PR existentes en vez de recrearlos, y salta lo ya mergeado. Volver
a correr `./ralph/once.sh` siempre es seguro.

## Fallos del revisor vs. rechazos

Un revisor que **no llegó a correr** (API 529, red caída, crash) no es un
rechazo. Si Claude no deja veredicto **ni comentario**, el loop lo trata como
fallo de infraestructura: reintenta con backoff (1, 3, 9 min) **sin consumir
ronda**. Agotados los reintentos, el issue queda sin revisar y su PR abierto y
**sin label**, para que un rerun lo retome.

Sin esto, una caída transitoria del proveedor quema las 3 rondas y manda a Codex
a "corregir" contra una revisión que nunca existió.

## Topes de uso

- **Tope de sesión** (de Claude o de Codex): no es un fallo del issue. El script
  espera a que reabra la ventana y reintenta el mismo issue.
- **Tope semanal**: para y escribe `ralph/last_run.md` con el estado para que
  reanudes a mano.

## Archivos

| Archivo | Rol |
|---|---|
| `once.sh` | Orquestador: selección de issues, ramas, merge, topes de uso |
| `prompt_implement.md` | Codex: implementar el issue y abrir el PR |
| `prompt_review.md` | Claude: revisar el PR y emitir el veredicto |
| `prompt_revise.md` | Codex: atender los comentarios de la revisión |
| `prompt_conflicts.md` | Codex: resolver los conflictos al poner la rama al día con la base |
| `VERSION` | Release instalada; la compara `update.sh --check` |
| `last_run.md` | Checkpoint, generado al parar por tope semanal (no se versiona) |

## Niveles de configuración

`ralph/` es **común e idéntica** en todos los repos que la usan: nunca se edita
en el proyecto. Lo que varía vive fuera de ella:

| Nivel | Ubicación | Contenido |
|---|---|---|
| Común | `ralph/` | Script, prompts, contratos, tests, updater, `VERSION` |
| Proyecto | `.ralph/config.env` | Base, labels, checks obligatorios, política de cierre, hook post-merge |
| Proyecto | `.ralph/prompt_*.local.md` | Restricciones concretas de implementación/revisión, anexadas al prompt común |
| Host | `~/.config/ralph/host.env` | Capacidad Linux/macOS, rutas (PATH de Homebrew, `gtimeout`), límites locales |
| Credenciales | Login / keychain / entorno protegido | Autenticación de `gh`, `codex`, `claude`; nunca en config versionada |

Precedencia: entorno explícito > host > proyecto > defaults. Los `.env` son
código shell de confianza (se hacen `source`), no datos parseados.

> Estado: la carga de `.ralph/` y `host.env` y la composición de prompts
> locales están planificadas (issues del repo `nicoamigosa/ralph`); hoy todo
> se configura por entorno.

## Configuración

Todo por entorno, todo opcional:

| Variable | Default |
|---|---|
| `RALPH_LABEL` | `ready-for-agent` |
| `RALPH_BASE_BRANCH` | trunk del repo (`main`/`master`) |
| `RALPH_BRANCH_PREFIX` | `ralph/issue-` |
| `RALPH_MAX_ROUNDS` | `3` |
| `RALPH_CODEX_MODEL` | `gpt-5.6-luna` |
| `RALPH_CODEX_EFFORT` | `xhigh` |
| `RALPH_CODEX_SANDBOX` | `workspace-write` |
| `RALPH_CLAUDE_MODEL` | `opus` |
| `RALPH_MERGE_METHOD` | `--squash` |
| `RALPH_NEEDS_HUMAN_LABEL` | `ralph-needs-human` |
| `RALPH_MAX_INFRA_RETRIES` | `3` |
| `RALPH_ISSUE_ORDER` | vacío (orden por número) |
| `RALPH_POST_MERGE_CHECK` | vacío (sin verificación de producción) |

## Distribución y versión

`ralph/` se distribuye como **release etiquetada** del repo
[`nicoamigosa/ralph`](https://github.com/nicoamigosa/ralph); `VERSION` dice
cuál está instalada. No se usa subtree ni submodule ni copia desde `main`:
ninguno fija ni verifica la versión que se ejecuta.

- Instalar/actualizar: `ralph/update.sh <VERSION>` descarga esa release,
  verifica su SHA-256, rechaza modificaciones locales en archivos comunes y
  aplica sólo los archivos del manifiesto; preserva `runs/`, checkpoints y toda
  `.ralph/`. Nunca se autoactualiza durante una corrida; el diff queda para un
  PR normal.
- Comprobar atraso: `ralph/update.sh --check` compara `VERSION` con la última
  release estable y responde "actual", "actualización disponible" o "consulta
  fallida" (una consulta fallida **no** significa estar al día).

> Estado: `update.sh` está planificado (issues del repo `nicoamigosa/ralph`).
> Hasta que exista, instalar es copiar el contenido del tag `v<VERSION>`.

## Notas de diseño

- **Claude comenta, el script mergea ("modo comentario").** GitHub rechaza
  `approve` y `request-changes` sobre un PR abierto por la misma cuenta, así
  que el revisor usa `gh pr comment` y el veredicto viaja en la última línea de
  su salida. El merge lo ejecuta el script, y sólo ante un `PASS` bien formado.
  Este modo **no equivale a una required review de GitHub**: el servidor no
  garantiza el PASS, sólo el script. Para que lo garantice hace falta una
  identidad de revisión/merge distinta del implementador y un ruleset sin
  bypass en la base; mientras no exista, el ruleset sólo puede exigir status
  checks.
- **El issue lo cierra el script, no el agente.** `Closes #N` sólo autocierra
  cuando el PR va contra la rama por defecto; acá la base es configurable.
- **Codex corre con `network_access=true`** dentro del sandbox `workspace-write`,
  que es lo mínimo que necesita para `git push` y `gh pr create`.
- **La rama se pone al día con la base antes de cada revisión**, con `git merge`
  y nunca `rebase`: el revisor ve lo que de verdad se va a mergear, y si hay
  conflictos los resuelve Codex sin consumir ronda.
- **CI verde es condición de merge además del PASS.** Con CI en rojo, el script
  deja el run fallido como único ítem de revisión y Codex corrige.
- **Un hook post-merge puede parar la corrida.** `RALPH_POST_MERGE_CHECK`
  recibe el SHA mergeado; si devuelve ≠0, el issue queda etiquetado y ralph no
  encadena otro despliegue sobre una producción que no verifica.
