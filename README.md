# Ralph

Resuelve issues de GitHub sin supervisión, con dos agentes y un gate real:

```
Codex (gpt-5.6-luna, xhigh)  implementa con la skill tdd  →  abre PR
Claude (opus)                devuelve la revisión         →  PASS ? merge : Codex corrige
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
usa `--match-head-commit` al mergear. Si GitHub tarda en reflejar un push recién
hecho, sólo reintenta `headRefOid` hasta 5 veces, esperando 2 segundos entre
lecturas; un `HEAD` local distinto falla de inmediato y nunca se revisa ni
mergea un SHA que el PR no confirme. `RALPH_MERGE_METHOD` sólo admite
`--squash`, `--merge` o `--rebase`; cualquier otro valor detiene el preflight.

## CI

La política de CI es `required` por defecto. Ralph distingue tres estados:

- **CI rojo:** un check terminó con fallo después de ejecutar steps. Ralph deja
  el detalle en el PR para que Codex lo corrija; no mergea.
- **CI pendiente:** faltan checks o siguen `queued`/`in_progress`. Ralph espera
  hasta `RALPH_CI_TIMEOUT_SECONDS` (30 minutos por defecto), deja el issue en
  `ci_pending` y no manda una corrección ni mergea.
- **Infraestructura (`ci_infrastructure`):** un job terminó en `failure` o
  `cancelled` sin ejecutar steps, o su anotación indica que no fue iniciado
  (por ejemplo, por facturación o límite de gasto). Ralph reintenta el poll hasta
  `RALPH_MAX_INFRA_RETRIES`, sin consumir una ronda ni comentar CI rojo; si
  persiste, detiene la corrida con rc 70. El mensaje cita la anotación y el
  comando `gh api repos/<slug>/check-runs/<id>/annotations`, y el motivo queda
  en `RUN_DIR/summary.json`.

Antes de consultar issues, el preflight inspecciona el último run de CI de la
base y exige que haya ejecutado al menos un step. Si no arrancó por esa
infraestructura, falla la corrida con `ci_infrastructure`. Para repos sin CI,
`RALPH_CI_POLICY=none` es una excepción explícita y queda avisada en la salida.

Cada corrida calcula un deadline global al comenzar: `RALPH_MAX_RUN_SECONDS`
(4 horas por defecto). También limita a `RALPH_MAX_ISSUES` (5 por defecto) los
issues únicos iniciados; los reintentos por tope no consumen otro cupo. Al vencer
cualquiera de esos límites, Ralph guarda checkpoint, termina sin iniciar otro
agente ni merge, y registra `stop_reason=deadline` o `stop_reason=max_issues`.
Las esperas de CI y de reset del proveedor se acotan al mismo deadline. El
preflight requiere una implementación GNU de `timeout`: elige `gtimeout` cuando
está disponible (Homebrew `coreutils` en macOS) y luego `timeout` en Linux; si
ninguna es usable, detiene la corrida con instrucciones de instalación.

`RALPH_CLAUDE_MAX_BUDGET_USD` agrega `--max-budget-usd` a cada invocación de
Claude, incluido el smoke test. `RALPH_RUN_BUDGET_USD` es un tope estimado de
coste de Claude para toda la corrida: cuando el coste acumulado reportado por
Claude alcanza o supera ese valor, Ralph no inicia otro agente y registra
`stop_reason=budget`. No es una medición exacta de facturación ni un presupuesto
conjunto de Claude y Codex; el techo duro de Codex se configura en su proveedor.

El proyecto puede declarar sus gates con
`RALPH_REQUIRED_CHECKS_JSON='["CI / test","ShellCheck"]'`. Ralph consulta los
`check-runs` y `statuses` del SHA exacto que revisó Claude: cada nombre declarado
debe terminar en `success`; `skipped`, `neutral`, `cancelled`, `pending` y los
resultados ausentes no habilitan el merge. Los checks exitosos adicionales no
reemplazan uno obligatorio. Si no se declara la lista, todos los resultados del
SHA deben ser exitosos y al menos uno debe existir.

La protección de la base también es `required` por defecto:
`RALPH_REQUIRE_PROTECTION=1` consulta los rulesets activos de la rama base,
comprueba que cubran los checks de `RALPH_REQUIRED_CHECKS_JSON` y rechaza
cualquier bypass para la identidad que mergea. Si se configura una identidad
revisora distinta con `RALPH_REVIEW_IDENTITY`, el ruleset debe exigir una
aprobación o el check `ralph-review`; antes del merge, esa aprobación o check
debe corresponder al SHA revisado y a esa identidad. `RALPH_REQUIRE_PROTECTION=0`
queda reservado al sandbox de pruebas, avisa explícitamente y se registra en
`RUN_DIR/summary.json`. La ausencia de `--auto` no desactiva esta protección:
el merge inmediato sigue respetando las reglas aplicables del servidor.

Después de pedir el merge, Ralph consulta el PR hasta confirmar `state=MERGED`
con un `mergeCommit.oid` SHA válido. El timeout es de 10 minutos por defecto y
se configura con `RALPH_MERGE_TIMEOUT_SECONDS`. Si el PR queda encolado hasta
vencerlo, registra `merge_pending`, conserva ramas y issue, y detiene la corrida
por defecto; `RALPH_MERGE_PENDING_POLICY=continue` permite seguir con otros
issues independientes.
Si GitHub ya borró la ref remota de la rama al completar el merge, Ralph la
considera eliminada y continúa con el borrado local, el hook post-merge y el
cierre del issue.

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

## Integración real con GitHub

La suite que usa GitHub real no forma parte de `bats tests/` ni de la CI normal.
Se lanza explícitamente con `make integration` o desde el workflow manual
`.github/workflows/integration.yml`. El destino por defecto es
`nicoamigosa/ralph-sandbox`; para otro sandbox se debe configurar el slug exacto
en ambos valores antes de ejecutar:

```bash
export REPO_SLUG=nicoamigosa/ralph-sandbox
export RALPH_SANDBOX_SLUGS=nicoamigosa/ralph-sandbox
export GH_TOKEN='token-con-contents-issues-y-pull-requests-write'
export RALPH_REVIEWER_GH_TOKEN='token-distinto-de-solo-lectura'
make integration
```

El harness compara `REPO_SLUG` con la allowlist antes de ejecutar `gh auth
setup-git`, clonar, crear issues o hacer cualquier otra escritura. Un slug fuera
de la allowlist termina con código 2. `GH_TOKEN` y
`RALPH_REVIEWER_GH_TOKEN` deben ser credenciales distintas; no se escriben en
archivos `.env`.

### Preparar `ralph-sandbox`

El sandbox debe tener el label `ready-for-agent` y un workflow de pull request
cuyo job se llame `test`. La prueba mínima puede ser:

```yaml
name: Sandbox CI
on: [pull_request, push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: test ! -e .ralph-integration-fail
```

En Settings → Rules → Rulesets, crear un ruleset activo para `main` que exija
el status check `test` y no tenga bypass actors. No exigir aprobaciones humanas:
la identidad que ejecuta la suite debe poder mergear cuando `test` está verde,
pero no debe saltarse el ruleset. El workflow debe estar en `main` antes de
lanzar la suite para que GitHub ejecute el check en cada PR.

La suite crea un issue por escenario, sustituye Codex y Claude por fixtures bajo
`tests/integration/`, y comprueba el estado remoto. Ejecuta, en orden, PASS con
CI verde (merge), PASS con CI rojo (PR abierto), rechazo (PR abierto con
comentario) y error del agente (sin merge). Al finalizar cierra los issues,
cierra los PR no mergeados y borra sus ramas. El PR mergeado permanece como
historial inmutable de GitHub; la limpieza garantiza que no queden PR abiertos
ni ramas de los escenarios. Se puede limitar la corrida, por ejemplo,
`RALPH_INTEGRATION_SCENARIOS=pass-green make integration`.

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
**working tree limpio** — el script salta entre ramas y mergea. Además,
`RALPH_TDD_SKILL` debe apuntar a un `SKILL.md` legible; Ralph lo agrega sólo al
contexto de Codex. Antes de consultar issues, el preflight valida las sesiones
de Codex (`codex login status`), Claude (`claude auth status --json`) y GitHub
(`gh auth status`), comprueba `jq` y verifica las versiones mínimas soportadas:
Codex `0.154.0`, Claude `2.1.277` y gh `2.45.0`. Las versiones quedan en
`run.log`, `summary.json` y `summary.md`.

`RALPH_SMOKE_TEST=1` habilita una llamada mínima a ambos modelos después del
preflight. Un modelo inaccesible detiene la corrida como error de configuración,
antes de listar o tocar issues; queda desactivado por defecto porque consume
presupuesto. El dry-run sigue sin exigir login de Codex o Claude, aunque sí
necesita `git`, `gh` y `jq` para construir el plan. En macOS,
instalá Bash con `brew install bash` y anteponé `$(brew --prefix bash)/bin` al
`PATH`. `once.sh` usa los formatos nativos de `date` para Darwin y Linux y
temporales bajo `${TMPDIR:-/tmp}`, sin requerir utilidades GNU adicionales. El
plan dry-run usa únicamente esas herramientas de lectura.

## Cómo elige los issues

1. Issues abiertos con el label `ready-for-agent`, **por número ascendente**.
   La consulta usa un límite explícito alto (`1000`) para no heredar el tope
   predeterminado de 30 resultados de `gh`; ese límite sólo afecta la consulta,
   no la cantidad de issues que el selector intenta procesar.
2. Antes de crear una rama, vuelve a leer y validar el body, el estado y los
   labels de cada candidato. Un `gh issue view` fallido detiene la pasada
   (nunca se interpreta como un body sin dependencias). Un issue con
   `ralph-needs-human` se omite, igual que un PR que tenga ese label.
3. Excluye los **épicos**: cualquier issue referenciado por otro bajo `## Parent`.
   Para detectarlos, Ralph inspecciona también hijos cerrados o sin el label de
   candidatos.
4. Respeta dependencias: salta los que tienen blockers abiertos bajo
   `## Blocked by`. El estado de cada blocker se consulta **en el momento de
   evaluarlo**, no del listado cacheado al inicio de la pasada: la API de GitHub
   es eventualmente consistente y justo tras cerrar un issue todavía lo devuelve
   abierto, bloqueando de mentira a sus dependientes. Consultarlo en vivo además
   los desbloquea dentro de la misma pasada (por eso el merge a la base ocurre
   antes de seguir: los dependientes heredan el código).

Antes de evaluar dependencias, Ralph detecta el host local con `uname -s`:
`Darwin` es `macos` y `Linux` es `linux`; cualquier otro sistema detiene la
corrida. Un issue con `ralph-host:macos` o `ralph-host:linux` sólo se procesa en
ese host. Sin ninguno de esos labels puede ejecutarse en ambos. Si tiene los dos,
los labels son contradictorios y el issue queda bloqueado explícitamente. El
dry-run muestra `host=<requerido> current=<actual>` por issue.

Antes de invocar a cada agente, Ralph repite la validación de estado, labels y
blockers. Si el issue pierde `ready-for-agent`, se cierra, se bloquea o recibe
`ralph-needs-human` mientras la corrida está en curso, no se invoca ningún
agente y la rama queda preservada para la siguiente pasada.

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

Al comenzar cada issue, Ralph ejecuta `git fetch origin`. Si la rama del issue
sólo existe en el remoto, la recupera con tracking y revisa el PR existente sin
volver a invocar Codex. Cuando existen ambas copias, exige igualdad o un
fast-forward; una divergencia conserva la rama, etiqueta el PR (o el issue si
no hay PR abierto) como `ralph-needs-human` y no lanza agentes.

Antes de implementar consulta PRs abiertos, cerrados y mergeados asociados a la
rama o al issue. Un PR ya mergeado con el issue todavía abierto se reconcilia
aplicando `RALPH_CLOSE_POLICY`, en lugar de crear otra rama o implementación.

Después del preflight, cada corrida normal aplica `umask 077`, genera un
`RUN_ID` UTC (`YYYYMMDDTHHMMSSZ-<pid>`) y guarda sus artefactos en
`$SCRIPT_DIR/runs/$RUN_ID/`. `run.log` recibe toda la salida posterior al
preflight; `events.log`, `last-message.txt`, `summary.json` y las capturas
separadas de stdout/stderr de cada agente quedan allí y se conservan al
terminar. `runs/` está ignorado por el `.gitignore` distribuido, y el dry-run
no crea ese directorio. El resumen siempre termina con un `stop_reason`
explícito; `issues_started` cuenta los issues únicos iniciados en la corrida;
un fallo de issue no se reporta como `no_ready_issues`.

Al salir, el trap conserva el código original y finaliza `summary.json` y
`summary.md`. El JSON incluye `run_id`, `stop_reason`, `issues_started`, `merged`, `open_prs`,
`needs_human`, `blocked`, `errors`, `elapsed_seconds` y `usage` con
`codex_tokens` y `claude_estimated_usd`. `versions.codex`,
`versions.claude` y `versions.gh` conservan las versiones observadas en el
preflight. Los cuatro estados de trabajo son listas con números y enlaces a
issues/PRs; `events.jsonl` conserva un evento
JSON por línea asociado al issue y, cuando existe, al PR. Un dato de uso que
el proveedor no entrega es `null`, nunca `0`. `claude_estimated_usd` es sólo
el coste estimado reportado por el proveedor: Ralph no calcula coste marginal
de una suscripción ni lo presenta como facturación real. El presupuesto de
corrida sólo cubre ese coste estimado de Claude; no es un presupuesto conjunto
con Codex.

Al terminar una corrida normal, Ralph imprime en stdout la ruta de
`summary.md`. Si `RALPH_REPORT_ISSUE` contiene un número de issue, publica ese
archivo como el único comentario adicional en el issue indicado. Si GitHub
rechaza la publicación, avisa, conserva el archivo y mantiene el código de
salida original de la corrida.

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
no hace checkout ni reset destructivo. También guarda el motivo y los datos de
la señal en el `summary.json` de la corrida.

Cada invocación de Codex o Claude, el hook `RALPH_POST_MERGE_CHECK` y las
esperas de CI/confirmación de merge pasan por un límite GNU `timeout --kill-after=30s`.
El límite efectivo nunca supera el tiempo restante de la corrida. Si vence una
orden, el estado es `timeout` —no un tope del proveedor—, se conserva la rama
cuando todavía existe y la corrida se detiene; un hook post-merge vencido también
impide encadenar otro issue.

## Adaptadores JSON de agentes

Codex se ejecuta con `codex exec --json -o "$LAST_MSG"` y Claude con
`claude --print --output-format json`. Cada ejecución conserva sus archivos
`<agente>-<n>.stdout.jsonl|json`, `<agente>-<n>.stderr.log` y
`<agente>-<n>.result.json` bajo `RUN_DIR`; stdout nunca se mezcla con stderr.

El contrato interno de ambos adaptadores es:

```json
{"status":"ok|rate_limited|auth_error|config_error|timeout|failed|unknown","retry_at":null,"limit_scope":"session|weekly|unknown","retryable":false,"exit_code":0,"final_message":null,"error":null}
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

Claude no publica comentarios: si la ejecución falla antes de devolver su
cuerpo, el estado remoto queda en `phase=revisión`, con la misma ronda y SHA,
para que el siguiente intento retome esa revisión sin consumir presupuesto.
Una respuesta válida se publica una sola vez como el cuerpo exacto; la ronda
sólo avanza después de que Codex completa la corrección.

Una respuesta sin veredicto bien formado, o un `CHANGES_REQUESTED` sin ningún
hallazgo numerado, se trata como fallo de infraestructura del revisor: se
reintenta hasta `RALPH_MAX_INFRA_RETRIES` sin consumir ronda ni publicar nada.
Agotados los reintentos sigue siendo `CHANGES_REQUESTED` (fail-closed). El
revisor corre con `--disallowedTools Monitor,ScheduleWakeup,CronCreate,Agent`
porque cada despertar de una herramienta de segundo plano es un turno nuevo y
`claude --print` devuelve sólo el último, perdiendo la revisión.

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
| `update.sh` | Descarga y verifica una release antes de actualizar la instalación |
| `MANIFEST` | Paths de los archivos que forman la distribución |
| `VERSION` | Release instalada; la comparará `update.sh --check` (#20) |
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

Al iniciar, Ralph resuelve la raíz con `git rev-parse --show-toplevel`, cambia
allí su directorio de trabajo y carga `.ralph/config.env`. Después carga
`${RALPH_HOST_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ralph/host.env}` si
existe. La precedencia es entorno explícito > host > proyecto > defaults; para
garantizarla, las variables `RALPH_*` que ya estaban en el entorno se capturan
antes de hacer `source` y se restauran al terminar la carga. Los `.env` son
código shell de confianza (se hacen `source`), no datos parseados: sólo deben
contener código que el operador haya auditado.

Los prompts comunes se leen desde `ralph/` antes de cambiar a la rama de un
issue. `load_prompt <name>` añade, si existe, `.ralph/<name>.local.md` bajo
`# Project-specific requirements`; allí viven las restricciones propias del
proyecto sin modificar los prompts distribuidos.

## Configuración

Salvo `RALPH_TDD_SKILL`, que es obligatorio, todo es opcional; puede venir del
entorno, `.ralph/config.env` o `host.env`:

| Variable | Default |
|---|---|
| `RALPH_LABEL` | `ready-for-agent` |
| `RALPH_BASE_BRANCH` | trunk del repo (`main`/`master`) |
| `RALPH_BRANCH_PREFIX` | `ralph/issue-` |
| `RALPH_MAX_ROUNDS` | `3` |
| `RALPH_MAX_ISSUES` | `5` |
| `RALPH_MAX_RUN_SECONDS` | `14400` |
| `RALPH_CODEX_MODEL` | `gpt-5.6-luna` |
| `RALPH_CODEX_EFFORT` | `xhigh` |
| `RALPH_CODEX_SANDBOX` | `workspace-write` (en este modo Codex monta `.git` como sólo lectura; ralph lo habilita como `writable_root` y ejecuta una sonda de preflight; `danger-full-access` no se recomienda) |
| `RALPH_CLAUDE_MODEL` | `opus` |
| `RALPH_TDD_SKILL` | obligatorio: ruta a un `SKILL.md` legible para Codex |
| `RALPH_SMOKE_TEST` | `0` (con `1`, prueba ambos modelos antes de consultar issues) |
| `RALPH_REVIEWER_GH_TOKEN` | obligatorio para el revisor: token fine-grained de GitHub, limitado a este repositorio y con permisos de lectura |
| `RALPH_REQUIRE_REVIEWER_TOKEN` | `1` (sólo `0` junto con `RALPH_REQUIRE_PROTECTION=0` en el sandbox) |
| `RALPH_MERGE_METHOD` | `--squash` |
| `RALPH_MERGE_TIMEOUT_SECONDS` | `600` |
| `RALPH_MERGE_PENDING_POLICY` | `stop` (`continue` es la alternativa explícita) |
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
| `RALPH_CLOSE_POLICY` | `verified` (valores admitidos: `verified` \| `never`) |
| `RALPH_REQUIRE_PROTECTION` | `1` |
| `RALPH_MERGE_IDENTITY` | vacío (login de `gh api user`) |
| `RALPH_REVIEW_IDENTITY` | vacío (sin identidad revisora separada) |
| `RALPH_ISSUE_ORDER` | vacío (orden por número) |
| `RALPH_REPORT_ISSUE` | vacío (no publica el resumen; si se define, comenta `summary.md` en ese issue) |
| `RALPH_POST_MERGE_CHECK` | vacío (sin verificación de producción) |
| `RUN_DIR` | `$SCRIPT_DIR/runs/<RUN_ID>` (capturas, eventos, `summary.json`/`.md` y contratos de agentes; override explícito conservado para pruebas) |
| `RALPH_CHECKPOINT_FILE` | `$SCRIPT_DIR/last_run.md` |
| `RALPH_HOST_CONFIG` | `${XDG_CONFIG_HOME:-$HOME/.config}/ralph/host.env` |

Con `RALPH_CODEX_SANDBOX=workspace-write`, ralph reemplaza cualquier
`writable_roots` configurado por el usuario en `~/.codex/config.toml` por la
raíz `.git` absoluta del repositorio actual. Antes del primer issue ejecuta una
sonda sin modelo que escribe y borra un archivo allí; si `codex sandbox` no está
disponible en la plataforma, avisa y continúa. `danger-full-access` evita esa
restricción, pero no se recomienda porque expone todo el filesystem.

El revisor recibe `RALPH_REVIEWER_GH_TOKEN` únicamente como `GH_TOKEN` de su
proceso hijo. El preflight exige que sea distinto del `GH_TOKEN` del
orquestador. Creá un token fine-grained con acceso sólo al repositorio objetivo
y permisos de lectura para `Metadata` (obligatorio en GitHub), `Contents`,
`Issues` y `Pull requests`; guardalo en el entorno protegido del host, nunca en
`.ralph/config.env` ni en un archivo versionado. `RALPH_REQUIRE_REVIEWER_TOKEN=0`
sólo se acepta junto con `RALPH_REQUIRE_PROTECTION=0`, reservado para el
sandbox; en ese caso el revisor no hereda `GH_TOKEN`.

Los procesos de Codex, Claude y `RALPH_POST_MERGE_CHECK` heredan el entorno
normal del host —incluidos `PATH`, credenciales y `TMPDIR`— excepto las
variables `RALPH_*`: la configuración de `once.sh` no se exporta a los agentes
ni al hook. `RALPH_POST_MERGE_CHECK` recibe el SHA del merge confirmado como
su primer y único argumento posicional (`$1`); cualquier dato adicional debe
provenir de su propio entorno no-`RALPH_*` o de archivos externos.

## Distribución y versión

`ralph/` se distribuye como **release etiquetada** del repo
[`nicoamigosa/ralph`](https://github.com/nicoamigosa/ralph); `VERSION` dice
cuál está instalada. No se usa subtree ni submodule ni copia desde `main`:
ninguno fija ni verifica la versión que se ejecuta.

- Instalar/actualizar: `ralph/update.sh <VERSION>` descarga esa release,
  verifica el tarball contra `SHA256SUMS`, rechaza modificaciones locales en
  archivos comunes y aplica sólo los paths de `MANIFEST`; preserva `runs/`,
  checkpoints y toda `.ralph/`. Mientras `once.sh` corre, el lock remoto
  `refs/ralph/lock` impide actualizar. El updater nunca crea commits: el diff
  queda para un PR normal.
- Comprobar atraso (pendiente, issue #20): `ralph/update.sh --check` comparará
  `VERSION` con la última release estable y responderá "actual", "actualización
  disponible" o "consulta fallida" (una consulta fallida **no** significa estar
  al día). Hoy `update.sh` rechaza `--check` y cualquier otra opción.

Cada release publica dos assets con nombres fijos: `ralph-v<VERSION>.tar.gz` y
`SHA256SUMS`. El segundo contiene el SHA-256 del primero. Para poder detectar
ediciones locales, `update.sh` también descarga y verifica el tarball de la
versión actualmente instalada antes de comparar sus archivos del `MANIFEST`.
Por eso los assets de releases anteriores deben conservarse.

### Publicar una release

Después de pasar `bash -n once.sh update.sh`, `shellcheck once.sh update.sh` y
`bats tests/`, versioná `VERSION`, commiteá y creá el tag `v<VERSION>`. Construí
el tarball desde `MANIFEST` para que no entren archivos fuera de la
distribución:

```bash
version="$(cat VERSION)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/ralph-release.XXXXXX")"
root="$stage/ralph-v$version"
mkdir -p "$root"
while IFS= read -r path || [ -n "$path" ]; do
  case "$path" in ''|'#'*) continue ;; esac
  mkdir -p "$root/$(dirname "$path")"
  cp -p "$path" "$root/$path"
done < MANIFEST
tar -czf "$stage/ralph-v$version.tar.gz" -C "$stage" "ralph-v$version"
(cd "$stage" && if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "ralph-v$version.tar.gz" > SHA256SUMS
else
  sha256sum "ralph-v$version.tar.gz" > SHA256SUMS
fi)
gh release create "v$version" "$stage/ralph-v$version.tar.gz" \
  "$stage/SHA256SUMS" --title "ralph $version"
```

La publicación se hace sólo después de que el tag exista en el remoto; el
tarball y su checksum deben corresponder exactamente a ese tag.

## Notas de diseño

- **Claude devuelve, Ralph publica y mergea.** Claude no usa `gh pr comment`:
  su resultado final contiene el cuerpo completo de la revisión y Ralph lo
  publica exactamente con `gh pr comment`. Después deja otro comentario remoto
  marcado `<!-- ralph-state -->` con el ID devuelto, PR, fase, ronda, SHA
  revisado, resultado y estado de merge. La reanudación reconstruye el último
  registro marcado desde GitHub, por lo que un comentario ajeno posterior no
  reemplaza la revisión que recibe Codex.
- **La credencial del revisor es de sólo lectura.** `RALPH_REVIEWER_GH_TOKEN`
  reemplaza el `GH_TOKEN` del orquestador sólo dentro del proceso de Claude,
  para que el revisor pueda inspeccionar el PR sin poder publicar comentarios
  ni mutaciones de GitHub. El token debe estar limitado al repositorio y a
  permisos de lectura; `RALPH_REQUIRE_REVIEWER_TOKEN=0` es una excepción sólo
  para el sandbox.
- **Límite conocido de v1:** no hay aislamiento por contenedor. Claude sigue
  ejecutándose con `--dangerously-skip-permissions` y puede acceder al workspace
  y a las capacidades locales que el host le entregue; v1 aísla únicamente la
  credencial GitHub usada por el revisor.
- El registro remoto usa eventos inmutables: antes de cada agente guarda la fase
  y la ronda actual, y sólo avanza la ronda después de completar la corrección.
  Un tope, timeout o reinicio retoma la misma fase, ronda y SHA. El merge se
  publica como `merge_pending` y `merged`, y sólo ante un `PASS` bien formado.
  Este modo **no equivale a una required review de GitHub**: el servidor no
  garantiza el PASS, sólo el script. Para que lo garantice hace falta una
  identidad de revisión/merge distinta del implementador y un ruleset sin
  bypass en la base; mientras no exista, el ruleset sólo puede exigir status
  checks.
- **El issue lo cierra el script, no el agente.** `Closes #N` sólo autocierra
  cuando el PR va contra la rama por defecto; acá la base es configurable.
- **El cierre depende de la política.** Con `RALPH_CLOSE_POLICY=verified`, el
  script cierra sólo después de PASS, merge confirmado y un `Closes #N` en el
  cuerpo del PR. Un `Part of #N`, o cualquier falta de esa declaración, deja el
  issue abierto y comenta el merge. Con `RALPH_CLOSE_POLICY=never`, nunca usa
  `gh issue close`, aunque el PR contenga `Closes #N`. El issue lo cierra el
  script, no el agente; el autocierre nativo de GitHub de `Closes #N` sólo
  aplica cuando el PR va contra la rama por defecto, pero `verified` hace
  explícito el cierre tras la verificación.
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
