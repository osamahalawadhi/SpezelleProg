#!/usr/bin/env bash
# cleanup-chatbot.sh
# Räumt alle Ressourcen auf UND kann optional auch die Verzeichnisse ./app und ./output löschen.
#
# Nutzung:
#   chmod +x cleanup-chatbot.sh
#   ./cleanup-chatbot.sh
#
# Steuerung per ENV (optional):
#   NAMESPACE=rag-bot
#   IMAGE=console-chatbot:latest
#   DELETE_NAMESPACE=true        # löscht gesamten Namespace
#   PURGE_IMAGES=true           # true ⇒ löscht Docker-Image $IMAGE
#   PURGE_OUTPUT=true           # true ⇒ löscht ./output/points.json
#   PURGE_OUTPUT_DIR=true       # true ⇒ löscht kompletten Ordner ./output rekursiv
#   PURGE_APP_DIR=true          # true ⇒ löscht kompletten Ordner $APP_DIR rekursiv (Standard: ./app)
#   APP_DIR=./app
#   DRY_RUN=false                # nur anzeigen
#
set -euo pipefail

# ---------- Konfiguration ----------
: "${NAMESPACE:=rag-bot}"
: "${IMAGE:=console-chatbot:latest}"
: "${DELETE_NAMESPACE:=true}"
: "${PURGE_IMAGES:=true}"
: "${PURGE_OUTPUT:=true}"
: "${PURGE_OUTPUT_DIR:=true}"
: "${PURGE_APP_DIR:=true}"
: "${APP_DIR:=./app}"
: "${DRY_RUN:=false}"
# -----------------------------------

log() { printf "\n%s\n" "==> $*"; }
info(){ printf "%s\n" "-- $*"; }
warn(){ printf "%s\n" "!! $*" >&2; }
run() {
  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

confirm_path_safe() {
  # simple Schutz: vermeidet versehentliches Löschen von /, $HOME, .
  local p="$1"
  local rp
  rp="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  if [ "$rp" = "/" ] || [ "$rp" = "$HOME" ] || [ "$rp" = "." ]; then
    warn "Unsicherer Pfad: $rp – Abbruch."
    exit 2
  fi
}

log "Starte Cleanup (Namespace=${NAMESPACE}, Image=${IMAGE})"

# --- Kubernetes ---
if have kubectl; then
  if [ "$DELETE_NAMESPACE" = "true" ]; then
    log "Kubernetes: Lösche gesamten Namespace '${NAMESPACE}'"
    if kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
      run "kubectl delete ns \"${NAMESPACE}\" --wait=true"
    else
      info "Namespace ${NAMESPACE} existiert nicht – überspringe."
    fi
  else
    log "Kubernetes: Selektives Löschen in '${NAMESPACE}'"
    if kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
      run "kubectl -n \"${NAMESPACE}\" delete deploy chatbot qdrant --ignore-not-found"
      run "kubectl -n \"${NAMESPACE}\" delete svc qdrant --ignore-not-found"
      run "kubectl -n \"${NAMESPACE}\" delete cm chatbot-config --ignore-not-found"
      run "kubectl -n \"${NAMESPACE}\" delete secret openai-secret --ignore-not-found"
      run "kubectl -n \"${NAMESPACE}\" delete job --all --ignore-not-found"
      run "kubectl -n \"${NAMESPACE}\" delete pod -l run=uploader --ignore-not-found || true"
      run "kubectl -n \"${NAMESPACE}\" delete pod -l run=curlbox --ignore-not-found || true"
      run "kubectl -n \"${NAMESPACE}\" delete pod -l run=qdrant-ensure --ignore-not-found || true"
    else
      info "Namespace ${NAMESPACE} existiert nicht – überspringe selektives Löschen."
    fi
  fi
else
  warn "kubectl nicht gefunden – überspringe Kubernetes-Cleanup."
fi

# --- Docker ---
if have docker; then
  log "Docker: Entferne temporäre Generator-Container (points-gen-*)"
  ids="$(docker ps -aq --filter 'name=points-gen-')" || ids=""
  if [ -n "${ids}" ]; then
    run "docker rm -f ${ids}"
  else
    info "Keine passenden Container gefunden."
  fi

  if [ "$PURGE_IMAGES" = "true" ]; then
    log "Docker: Entferne Image ${IMAGE}"
    img_id="$(docker images -q "${IMAGE}" || true)"
    if [ -n "${img_id}" ]; then
      run "docker rmi -f \"${IMAGE}\""
    else
      info "Image ${IMAGE} nicht gefunden – überspringe."
    fi
  else
    info "Docker-Image bleibt erhalten (PURGE_IMAGES=false)."
  fi
else
  warn "docker nicht gefunden – überspringe Docker-Cleanup."
fi

# --- Lokale Dateien/Verzeichnisse ---
if [ "$PURGE_OUTPUT" = "true" ]; then
  log "Lösche lokale Output-Datei ./output/points.json (falls vorhanden)"
  if [ -f "./output/points.json" ]; then
    run "rm -f ./output/points.json"
  else
    info "Keine ./output/points.json gefunden – überspringe."
  fi
fi

if [ "$PURGE_OUTPUT_DIR" = "true" ]; then
  if [ -d "./output" ]; then
    log "Lösche Ordner ./output rekursiv"
    confirm_path_safe "./output"
    run "rm -rf ./output"
  else
    info "Ordner ./output existiert nicht – überspringe."
  fi
else
  info "Ordner ./output bleibt erhalten (PURGE_OUTPUT_DIR=false)."
fi

if [ "$PURGE_APP_DIR" = "true" ]; then
  if [ -d "${APP_DIR}" ]; then
    log "Lösche Ordner ${APP_DIR} rekursiv"
    confirm_path_safe "${APP_DIR}"
    run "rm -rf \"${APP_DIR}\""
  else
    info "Ordner ${APP_DIR} existiert nicht – überspringe."
  fi
else
  info "Ordner ${APP_DIR} bleibt erhalten (PURGE_APP_DIR=false)."
fi

log "Cleanup abgeschlossen."
