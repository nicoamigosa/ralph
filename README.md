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

La revisión, los checks y el merge quedan ligados al mismo SHA: Ralph compara el
`HEAD` local con `headRefOid` antes y después de revisar, exige un árbol limpio y
usa `--match-head-commit` al mergear. `RALPH_MERGE_METHOD` sólo admite
`--squash`, `--merge` o `--rebase`; cualquier otro valor detiene el preflight.

La política de CI es `required` por defecto. Si GitHub todavía no reporta checks,
Ralph espera hasta `RALPH_CI_TIMEOUT_SECONDS` (30 minutos por defecto), deja el
issue en estado `ci_pending` y no manda una corrección a Codex ni mergea. Un
fallo explícito de un check sí se comenta en el PR para Codex. Para repos sin CI,
`RALPH_CI_POLICY=none` es una excepción explícita y queda avisada en la salida.

El proyecto puede declarar sus gates con
`RALPH_REQUIRED_CHECKS_JSON='["CI / test","ShellCheck"]'`. Ralph consulta los
`check-runs` y `statuses` del SHA exacto que revisó Claude: cada nombre declarado
debe terminar en `success`; `skipped`, `neutral`, `cancelled`, `pending` y los
resultados ausentes no habilitan el merge. Los checks exitosos adicionales no
reemplazan uno obligatorio. Si no se declara la lista, todos los resultados del
SHA deben ser exitosos y al menos uno debe existir.

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
checkout, agentes, labels, push o merge. También lee la ref remota de lock: si
hay otra corrida activa lo informa y nunca reclama ni modifica esa ref. Sirve
para inspeccionar una corrida sin modificar el repositorio ni GitHub.

Requisitos para una corrida completa: Bash **5 o superior**, `git`, `gh`
(autenticado, scope `repo`), `jq`, `codex`, `claude`, remoto `origin`, y
**working tree limpio** — el script salta entre ramas y mergea. En macOS,
instalá Bash con `brew install bash` y anteponé `$(brew --prefix bash)/bin` al
`PATH`. `once.sh` usa los formatos nativos de `date` para Darwin y Linux y
temporales bajo `${TMPDIR:-/tmp}`, sin requerir utilidades GNU adicionales. El
dry-run sólo necesita las herramientas de lectura (`git` y `gh`).

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

Los encabezados de estas secciones se comparan sin distinguir mayúsculas y
la sección termina en el siguiente `## `. Cada referencia debe ocupar una
línea completa (`#N` o `- #N`, con espacios opcionales); se tolera un `\r`
final. En `## Blocked by`, cualquier línea no vacía fuera de ese formato
bloquea el issue y Ralph informa explícitamente el error.

## Idempotencia

Si una corrida se corta (Ctrl-C, tope de uso, caída), la siguiente **reutiliza**
la rama y el PR existentes en vez de recrearlos, y salta lo ya mergeado. Volver
a correr `./ralph/once.sh` siempre es seguro.

## Exclusión entre hosts

Cada corrida normal adquiere atómicamente `refs/ralph/lock` en `origin` con un
`git push` de creación. El commit de la ref contiene host, PID, inicio y último
heartbeat; mientras la corrida está activa, Ralph lo renueva con un
`--force-with-lease` y lo libera con el mismo lease en el trap de salida. Una
segunda corrida, incluso desde WSL o macOS, sale antes de seleccionar issues,
agentes, labels, push o merge.

El heartbeat se considera vencido después de `RALPH_LOCK_TTL_SECONDS` y puede
reclamarse con otro compare-and-swap atómico. El valor por defecto es dos veces
`RALPH_AGENT_TIMEOUT_SECONDS`. La reclamación imprime el host y PID anteriores;
un lock con metadatos inválidos detiene la corrida (fail-closed). El dry-run
sólo lee esta ref y nunca la crea, renueva, reclama ni libera.

Ralph nunca crea commits para tapar trabajo que Codex dejó sin commitear: conserva
el árbol y detiene la corrida con código 70 para que el estado pueda recuperarse
manualmente. También detiene la corrida ante fallos de `checkout`, `fetch`,
`push` o `pull --ff-only`; un conflicto que Codex no resuelve se aborta cuando
es posible, conserva el árbol si no lo es y deja el PR etiquetado para un humano.

## Procesos

Cada `codex exec` y `claude` se lanza en su propia sesión/grupo de procesos.
Cuando existe `setsid` se usa para crear la sesión; en macOS sin `setsid`, Bash
5 usa job control (`set -m`) para obtener un grupo separado. stdout y stderr se
transmiten por capturas separadas, pero el grupo del agente queda aislado del
grupo de `once.sh`: una señal dirigida al agente no termina el orquestador.

Al terminar un agente, Ralph termina su grupo completo, incluidos procesos
huérfanos como servidores, watchers o tests colgados. Comprueba que el grupo no
sea el suyo antes de hacerlo, por lo que nunca se mata a sí mismo. Un agente que
termina por señal (`rc >= 128`) es un fallo de infraestructura: no produce
veredicto ni éxito.

`once.sh` atiende `TERM`, `INT` y `HUP`. Registra la señal, la fase y el issue,
conserva el árbol y la rama en el estado en que estaban y sale con `128 + señal`;
no hace checkout ni reset destructivo. Cuando `RUN_DIR` está configurado y ya
existe allí `summary.json`, también guarda allí el motivo y los datos de la señal.

## Adaptadores JSON de agentes

Codex se ejecuta con `codex exec --json -o "$LAST_MSG"` y Claude con
`claude --print --output-format json`. Cada ejecución conserva sus archivos
`<agente>-<n>.stdout.jsonl|json`, `<agente>-<n>.stderr.log` y
`<agente>-<n>.result.json` bajo `RUN_DIR`; si no se define, Ralph crea un
directorio temporal `ralph-run-<pid>` bajo `${TMPDIR:-/tmp}`. stdout nunca se
mezcla con stderr.

El contrato interno de ambos adaptadores es:

```json
{"status":"ok|rate_limited|auth_error|config_error|failed|unknown","retry_at":null,"limit_scope":"session|weekly|unknown","retryable":false,"exit_code":0,"final_message":null,"error":null}
```

`ok` exige exit code cero y una salida terminal válida: `turn.completed` para
Codex y un objeto `type=result` con campo `result` para Claude. JSON inválido,
truncado o sin resultado terminal es `failed`; el gate no mergea ese issue.

Las salidas soportadas y sus fixtures versionados son Codex CLI **0.154.x**
(`tests/fixtures/codex-0.154.0-*.jsonl`) y Claude Code **2.1.x**
(`tests/fixtures/claude-2.1.277-success.json`). Una actualización de cualquiera
de esos formatos requiere actualizar primero el fixture y el adaptador.

Los fixtures se capturaron de ejecuciones reales en este host. Codex CLI
reportó la versión 0.154.0 con codex --version y Claude Code reportó la versión
2.1.277 con claude --version.

El comando exacto de captura de Codex fue:

    codex exec --json -o "$capture_dir/last-message.txt" --skip-git-repo-check "Respond with exactly: real codex fixture capture. Do not modify files, run commands, or use tools."

El comando exacto de captura de Claude fue:

    claude --model opus --dangerously-skip-permissions --print --output-format json "Respond with exactly: <verdict>PASS</verdict>. Do not modify files, run commands, or use tools."

En ambas ejecuciones stdout y stderr se redirigieron a archivos separados; los
fixtures contienen el stdout crudo. codex-0.154.0-truncated.jsonl es el mismo
stdout real de Codex cortado a mitad del evento turn.completed.

## Fallos del revisor vs. rechazos

Un revisor que **no llegó a correr** (API 529, red caída, crash) no es un
rechazo. Si Claude no deja veredicto **ni comentario**, el loop lo trata como
fallo de infraestructura: reintenta con backoff (1, 3, 9 min) **sin consumir
ronda**. Agotados los reintentos, el issue queda sin revisar y su PR abierto y
**sin label**, para que un rerun lo retome.

Sin esto, una caída transitoria del proveedor quema las 3 rondas y manda a Codex
a "corregir" contra una revisión que nunca existió.

## Topes de uso

Los adaptadores clasifican un tope sólo desde un evento de error o metadatos
estructurados del proveedor. Respuestas, diffs, mensajes finales y salida de
herramientas no son señales de uso. Un `retry_at` sólo se acepta como epoch o
timestamp RFC3339 con zona dentro de esa señal; si falta, queda `null` y el
reintento es inmediato, sin inventar una sesión o una semana.

Cada issue admite como máximo `RALPH_MAX_LIMIT_RETRIES` reintentos. Un reset
fiable se espera sólo hasta ese instante y queda acotado por
`RALPH_DEADLINE_EPOCH` cuando existe. `auth_error` y `config_error` detienen la
corrida y escriben checkpoint; `unknown` registra el error y no espera.

## Archivos

| Archivo | Rol |
|---|---|
| `once.sh` | Orquestador: selección de issues, ramas, merge, topes de uso |
| `prompt_implement.md` | Codex: implementar el issue y abrir el PR |
| `prompt_review.md` | Claude: revisar el PR y emitir el veredicto |
| `prompt_revise.md` | Codex: atender los comentarios de la revisión |
| `prompt_conflicts.md` | Codex: resolver los conflictos al poner la rama al día con la base |
| `VERSION` | Release instalada; la compara `update.sh --check` |
| `last_run.md` | Checkpoint, generado al detenerse por límite/error global (no se versiona) |

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
| `RALPH_CODEX_SANDBOX` | `workspace-write` (en este modo Codex monta `.git` como sólo lectura; ralph lo habilita como `writable_root` y ejecuta una sonda de preflight; `danger-full-access` no se recomienda) |
| `RALPH_CLAUDE_MODEL` | `opus` |
| `RALPH_MERGE_METHOD` | `--squash` |
| `RALPH_NEEDS_HUMAN_LABEL` | `ralph-needs-human` |
| `RALPH_MAX_INFRA_RETRIES` | `3` |
| `RALPH_MAX_LIMIT_RETRIES` | `3` |
| `RALPH_DEADLINE_EPOCH` | vacío (sin deadline global) |
| `RALPH_CI_POLICY` | `required` |
| `RALPH_CI_TIMEOUT_SECONDS` | `1800` |
| `RALPH_REQUIRED_CHECKS_JSON` | vacío (usa todos los checks reportados) |
| `RALPH_AGENT_TIMEOUT_SECONDS` | `1800` (base del TTL del lock) |
| `RALPH_LOCK_REF` | `refs/ralph/lock` |
| `RALPH_LOCK_TTL_SECONDS` | `2 × RALPH_AGENT_TIMEOUT_SECONDS` |
| `RALPH_LOCK_HEARTBEAT_SECONDS` | mitad del TTL (mínimo `1`) |
| `RALPH_LOCK_HOST` | nombre del host (`uname -n`) |
| `RALPH_ISSUE_ORDER` | vacío (orden por número) |
| `RALPH_POST_MERGE_CHECK` | vacío (sin verificación de producción) |
| `RUN_DIR` | `${TMPDIR:-/tmp}/ralph-run-<pid>` (capturas y contratos de agentes) |
| `RALPH_CHECKPOINT_FILE` | `$SCRIPT_DIR/last_run.md` |

Con `RALPH_CODEX_SANDBOX=workspace-write`, ralph reemplaza cualquier
`writable_roots` configurado por el usuario en `~/.codex/config.toml` por la
raíz `.git` absoluta del repositorio actual. Antes del primer issue ejecuta una
sonda sin modelo que escribe y borra un archivo allí; si `codex sandbox` no está
disponible en la plataforma, avisa y continúa. `danger-full-access` evita esa
restricción, pero no se recomienda porque expone todo el filesystem.

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
