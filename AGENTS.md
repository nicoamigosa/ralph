# Ralph — Working agreement

Ralph es el orquestador Bash que resuelve issues de GitHub sin supervisión
(ver `README.md`). Este repo es la fuente común: lo que se etiqueta aquí como
release es lo que otros proyectos instalan como `ralph/`. Este archivo es la
única fuente de verdad para agentes.

## Reglas

- Bash ≥ 5 como orquestador; nada se reescribe en POSIX, Python ni TypeScript.
- Todo debe correr en Linux (WSL) y en macOS con Bash de Homebrew y utilidades
  BSD. No instalar GNU sed/grep/date para resolver diferencias: helpers.
- Fail-closed: ante duda, error de infraestructura o dato ausente, **no se
  mergea**. Nunca convertir un resultado incompleto en PASS.
- Nunca destruir trabajo del agente: sin `reset --hard`, sin autocommit.
- Comportamiento nuevo → test primero (skill `tdd`), con `codex`/`claude`/`gh`
  falsos por PATH; nunca invocar agentes de pago ni escribir en GitHub desde
  los tests.

## Gates

1. `bash -n once.sh` y `shellcheck once.sh` sin errores.
2. `bats tests/` — la suite completa, en Linux y macOS (CI).
3. `<verdict>PASS</verdict>` del revisor.

Nunca debilitar un gate: sin tests saltados ni umbrales bajados.

## Workflow

- Issues listos: label `ready-for-agent`; los que necesitan decisión humana:
  `ralph-needs-human`. Dependencias en `## Blocked by` (`- #N` por línea).
- Una rama por issue desde `main`: `ralph/issue-<N>`.
- Commit con `Closes #<N>` (o `Part of #<N>` si no está verificablemente
  hecho) y trailer `Co-Authored-By` del agente.
- PR contra `main` con las secciones que exige `prompt_implement.md`.
- Al cambiar comportamiento visible, actualizar `README.md`. `VERSION` sólo se
  toca al cortar una release.
