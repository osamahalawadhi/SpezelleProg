#!/usr/bin/env bash
# build-deploy-chatbot.sh
# All-in-One Script:
#  1) Build-Kontext erzeugen (Dockerfile, requirements.txt, chatbot.py, main.py – nur wenn fehlen)
#  2) Docker-Image bauen
#  3) points.json ERZEUGEN (im Container via main.py → ./output/points.json)
#  4) Kubernetes-Ressourcen anlegen/aktualisieren (Namespace, Secret, ConfigMap, Qdrant Deployment/Service, Chatbot Deployment)
#  5) Collection idempotent anlegen
#  6) points.json importieren
#  7) Funktionstests
#
# Nutzung:
#   chmod +x build-deploy-chatbot.sh
#   ./build-deploy-chatbot.sh
#
# Konfiguration (kann per ENV überschrieben werden):
#   APP_DIR=./app
#   IMAGE=console-chatbot:latest
#   NAMESPACE=rag-bot
#   COLLECTION=thema_ki
#   EMBED_SIZE=1536
#   QDRANT_URL=http://qdrant:6333
#   EMBED_MODEL=text-embedding-3-small
#   MIN_SCORE=0.65
#   TOP_K=5
#   OPENAI_KEY=sk-...
#   TOPIC="Grundlagen der künstlichen Intelligenz"
#   MAX_CHUNKS=3
#   POINTS_FILE=./output/points.json
#   TEST_QUESTION="Was versteht man unter maschinellem Lernen?"
set -euo pipefail

# ---------- Konfiguration (per ENV überschreibbar) ----------
: "${APP_DIR:=./app}"
: "${IMAGE:=console-chatbot:latest}"
: "${NAMESPACE:=rag-bot}"
: "${COLLECTION:=thema_ki}"
: "${EMBED_SIZE:=1536}"                # z. B. text-embedding-3-small
: "${QDRANT_SVC:=qdrant}"
: "${QDRANT_URL:=http://qdrant:6333}"
: "${EMBED_MODEL:=text-embedding-3-small}"
: "${MIN_SCORE:=0.65}"
: "${TOP_K:=5}"
: "${OPENAI_KEY:=your-openai-api-key}"
: "${TOPIC:=Grundlagen der künstlichen Intelligenz}"
: "${MAX_CHUNKS:=3}"
: "${POINTS_FILE:=./output/points.json}"
: "${TEST_QUESTION:=Was versteht man unter maschinellem Lernen?}"
# ------------------------------------------------------------

log()   { printf "\n%s\n" "==> $*"; }
die()   { echo "Fehler: $*" >&2; exit 1; }
need()  { command -v "$1" >/dev/null 2>&1 || die "Benötigtes CLI nicht gefunden: $1"; }

need docker
need kubectl

mkdir -p "$APP_DIR" output

# --- (1) Build-Dateien nur anlegen, wenn sie fehlen ---
if [ ! -f "${APP_DIR}/Dockerfile" ]; then
  log "Erzeuge ${APP_DIR}/Dockerfile"
  cat > "${APP_DIR}/Dockerfile" <<'DOCKER'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["python", "chatbot.py"]
DOCKER
fi

if [ ! -f "${APP_DIR}/requirements.txt" ]; then
  log "Erzeuge ${APP_DIR}/requirements.txt"
  cat > "${APP_DIR}/requirements.txt" <<'REQ'
openai>=1.0.0
requests>=2.32.0
python-slugify>=8.0.4
REQ
fi

# Chatbot (nur erzeugen, wenn nicht vorhanden)
if [ ! -f "${APP_DIR}/chatbot.py" ]; then
  log "Erzeuge ${APP_DIR}/chatbot.py"
  cat > "${APP_DIR}/chatbot.py" <<'PY'
import os, sys, json, re, requests
from textwrap import fill
from openai import OpenAI

OPENAI_API_KEY = (os.environ.get("OPENAI_API_KEY") or "").strip() or "PLEASE_SET_OR_USE_ENV"
QDRANT_URL     = (os.environ.get("QDRANT_URL") or "").strip() or "http://qdrant:6333"
COLLECTION     = (os.environ.get("QDRANT_COLLECTION") or "").strip() or "thema_ki"
EMBED_MODEL    = (os.environ.get("EMBED_MODEL") or "").strip() or "text-embedding-3-small"
TOP_K          = int((os.environ.get("TOP_K") or "").strip() or 5)
MIN_SCORE      = float((os.environ.get("MIN_SCORE") or "").strip() or 0.65)
WRAP_COLS      = int((os.environ.get("WRAP_COLS") or "").strip() or 100)

def fatal(msg: str, code: int = 2):
    print(f"Fehler: {msg}", file=sys.stderr); sys.exit(code)

def embed_query(client: OpenAI, text: str):
    resp = client.embeddings.create(model=EMBED_MODEL, input=[text])
    return resp.data[0].embedding

def qdrant_search(vector):
    import json, requests
    url = f"{QDRANT_URL}/collections/{COLLECTION}/points/search"
    body = {"vector": vector, "limit": TOP_K, "with_payload": True, "with_vector": False}
    r = requests.post(url, headers={"Content-Type":"application/json"}, data=json.dumps(body), timeout=60)
    if r.status_code >= 400: fatal(f"Qdrant-Suche fehlgeschlagen ({r.status_code}): {r.text}", 3)
    return r.json().get("result", [])

def answer_from_hits(hits):
    if not hits: return "Ich weiß es nicht auf Basis der vorhandenen Daten."
    if hits[0].get("score",0.0) < MIN_SCORE: return "Ich weiß es nicht auf Basis der vorhandenen Daten."
    lines=[]
    for i,h in enumerate(hits,1):
        p=h.get("payload",{}) or {}; s=h.get("score",0.0)
        title=p.get("title", f"Treffer {i}"); content=p.get("content","")
        source=p.get("source","unbekannt"); doc=p.get("doc_id","-"); cid=p.get("chunk_id","-")
        lines.append(f"[{i}] {title} (score={s:.3f})")
        if content: lines.append(fill(content, width=WRAP_COLS))
        lines.append(f"Quelle: {source} | doc_id={doc} | chunk={cid}"); lines.append("")
    return "\n".join(lines).strip()

def startup_check():
    import requests
    try:
        r = requests.get(f"{QDRANT_URL}/collections/{COLLECTION}", timeout=5)
        return r.status_code == 200
    except Exception: return False

def main():
    if not OPENAI_API_KEY or OPENAI_API_KEY == "PLEASE_SET_OR_USE_ENV":
        fatal("OPENAI_API_KEY fehlt. Bitte Secret/ENV setzen oder in chatbot.py eintragen.", 2)
    client = OpenAI(api_key=OPENAI_API_KEY)

    print("Console-Chatbot (Qdrant, nur Datenbankinhalte).")
    print("Frage eingeben und Enter drücken. Mit ':exit' beenden.")
    print(f"Collection: {COLLECTION} @ {QDRANT_URL}")
    print(f"Schwellwert (MIN_SCORE): {MIN_SCORE} | Top-K: {TOP_K}")
    if not startup_check(): print("Hinweis: Konnte Collection nicht sicher prüfen. Fahre dennoch fort.", file=sys.stderr)
    print("-"*60)

    try:
        while True:
            try: q = input("> ").strip()
            except (EOFError, KeyboardInterrupt): print("\nTschüss."); break
            if not q: continue
            if q.lower() in {":exit","exit","quit",":q"}: print("Tschüss."); break
            try:
                vec = embed_query(client, q)
            except Exception as e:
                print(f"Embedding-Fehler: {e}", file=sys.stderr); continue
            try:
                hits = qdrant_search(vec)
            except Exception as e:
                print(f"Qdrant-Fehler: {e}", file=sys.stderr); continue
            try:
                print("Top-Scores:", [ round(h.get("score",0.0),3) for h in hits ])
            except Exception: pass
            print(); print(answer_from_hits(hits)); print("-"*60)
    except Exception as e: fatal(f"Unerwarteter Fehler: {e}", 1)

if __name__ == "__main__": main()
PY
fi

# Generator-Skript (nur anlegen, wenn nicht vorhanden)
if [ ! -f "${APP_DIR}/main.py" ]; then
  log "Erzeuge ${APP_DIR}/main.py (Generator für points.json)"
  cat > "${APP_DIR}/main.py" <<'PY'
import os, sys, json
from datetime import datetime, timezone
from slugify import slugify
from openai import OpenAI

EMBED_MODEL = (os.environ.get("EMBED_MODEL") or "").strip() or "text-embedding-3-small"
GEN_MODEL   = (os.environ.get("GEN_MODEL") or "").strip() or "gpt-4o-mini"

def utcnow_iso(): return datetime.now(timezone.utc).isoformat()

def gen_chunks(client: OpenAI, topic: str, max_chunks: int = 3):
    system = ("Erzeuge prägnante, faktenbasierte Textabschnitte (Chunks) für ein Thema. "
              "Jeder Chunk 2–4 Sätze, klare Sprache. Keine Aufzählungslisten, kein Marketing.")
    user = (f"Thema: {topic}\nErzeuge {max_chunks} Chunks. Gib ein JSON-Array zurück, "
            f"mit Objekten: title, content, tags (Array kurzer Stichworte).")
    resp = client.chat.completions.create(
        model=GEN_MODEL,
        messages=[{"role":"system","content":system},{"role":"user","content":user}],
        temperature=0.2, max_tokens=800
    )
    text = resp.choices[0].message.content.strip()
    start, end = text.find("["), text.rfind("]")
    if start == -1 or end == -1: raise ValueError("Antwort enthält kein JSON-Array.")
    return json.loads(text[start:end+1])[:max_chunks]

def embed_texts(client: OpenAI, texts):
    resp = client.embeddings.create(model=EMBED_MODEL, input=texts)
    return [item.embedding for item in resp.data]

def main():
    topic = (os.environ.get("TOPIC") or "").strip() or "Grundlagen der künstlichen Intelligenz"
    api_key = (os.environ.get("OPENAI_API_KEY") or "").strip()
    if not api_key:
        print("Fehler: OPENAI_API_KEY fehlt.", file=sys.stderr); sys.exit(2)
    max_chunks = int((os.environ.get("MAX_CHUNKS") or "3").strip() or "3")
    out_dir = (os.environ.get("OUT_DIR") or "/data").strip() or "/data"

    client = OpenAI(api_key=api_key)
    print(f"Thema: {topic} | Chunks: {max_chunks} | Modell: {EMBED_MODEL}")
    chunks = gen_chunks(client, topic, max_chunks=max_chunks)
    contents = [c.get("content","") for c in chunks]
    vecs = embed_texts(client, contents)

    created_at = utcnow_iso()
    doc_id = f"doc-{slugify(topic) or 'topic'}"
    out_points = []
    for i, (chunk, vec) in enumerate(zip(chunks, vecs), start=1):
        out_points.append({
            "id": i,
            "vector": vec,
            "payload": {
                "title":   chunk.get("title", f"Chunk {i}"),
                "content": chunk.get("content",""),
                "tags":    chunk.get("tags", []),
                "language": "de",
                "source": f"generated:{doc_id}",
                "doc_id": doc_id,
                "chunk_id": i,
                "chunk_count": len(chunks),
                "created_at": created_at,
                "topic": topic
            }
        })

    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "points.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"points": out_points}, f, ensure_ascii=False, indent=2)
    print("Fertig. Datei:", out_path, "| Punkte:", len(out_points))

if __name__ == "__main__": main()
PY
fi

# --- (2) Docker-Image bauen ---
log "Baue Docker-Image: $IMAGE"
docker build -t "$IMAGE" "$APP_DIR"

# --- (3) points.json ERZEUGEN ohne File-Sharing (docker cp) ---
if [ -z "${OPENAI_KEY}" ]; then
  read -rsp "Bitte OPENAI API-Key eingeben (wird nicht angezeigt): " OPENAI_KEY
  echo
  [ -n "$OPENAI_KEY" ] || die "OPENAI API-Key ist leer."
fi

CONTAINER_NAME="points-gen-$$"
log "Erzeuge points.json im Container (ohne Host-Mount) → ${CONTAINER_NAME}"
# Vorherigen evtl. Container gleichen Namens entsorgen
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

# Container laufen lassen (kein --rm, damit wir docker cp nutzen können)
docker run --name "${CONTAINER_NAME}" \
  -e OPENAI_API_KEY="${OPENAI_KEY}" \
  -e TOPIC="${TOPIC}" \
  -e MAX_CHUNKS="${MAX_CHUNKS}" \
  -e EMBED_MODEL="${EMBED_MODEL}" \
  -e GEN_MODEL="gpt-4o-mini" \
  -e OUT_DIR="/data" \
  "${IMAGE}" \
  python main.py

# points.json herauskopieren
mkdir -p "$(dirname "${POINTS_FILE}")"
docker cp "${CONTAINER_NAME}:/data/points.json" "${POINTS_FILE}"

# Aufräumen
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

# Sicherstellen, dass die Datei vorhanden ist
test -f "${POINTS_FILE}" || die "points.json wurde nicht erzeugt/kopiert: ${POINTS_FILE}"

# --- (4) Namespace/Secret/ConfigMap ---
log "Sorge für Namespace: ${NAMESPACE}"
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

log "Erzeuge/aktualisiere Secret openai-secret"
kubectl -n "${NAMESPACE}" apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: openai-secret
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  OPENAI_API_KEY: "${OPENAI_KEY}"
YAML

log "Erzeuge/aktualisiere ConfigMap chatbot-config"
kubectl -n "${NAMESPACE}" apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: chatbot-config
  namespace: ${NAMESPACE}
data:
  QDRANT_URL: "${QDRANT_URL}"
  QDRANT_COLLECTION: "${COLLECTION}"
  EMBED_MODEL: "${EMBED_MODEL}"
  MIN_SCORE: "${MIN_SCORE}"
  TOP_K: "${TOP_K}"
YAML

# --- (5) Qdrant Deployment + Service ---
log "Deploye/aktualisiere Qdrant (Deployment + Service)"
kubectl -n "${NAMESPACE}" apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${QDRANT_SVC}
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels: { app: ${QDRANT_SVC} }
  template:
    metadata:
      labels: { app: ${QDRANT_SVC} }
    spec:
      containers:
      - name: qdrant
        image: qdrant/qdrant:latest
        ports:
        - containerPort: 6333
        - containerPort: 6334
        volumeMounts:
        - name: data
          mountPath: /qdrant/storage
      volumes:
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ${QDRANT_SVC}
  namespace: ${NAMESPACE}
spec:
  selector: { app: ${QDRANT_SVC} }
  ports:
  - name: http
    port: 6333
    targetPort: 6333
  - name: grpc
    port: 6334
    targetPort: 6334
YAML

log "Warte auf Qdrant Bereitstellung"
kubectl -n "${NAMESPACE}" wait --for=condition=available "deploy/${QDRANT_SVC}" --timeout=120s

# --- (6) Collection idempotent anlegen ---
log "Stelle Collection '${COLLECTION}' sicher (idempotent)"
kubectl -n "${NAMESPACE}" run qdrant-ensure --rm -i --restart=Never \
  --image=curlimages/curl:8.9.0 --command -- \
  sh -lc "set -e; if curl -sf ${QDRANT_URL}/collections/${COLLECTION} >/dev/null; then echo '✔ Collection ${COLLECTION} existiert – überspringe Create.'; else echo '➕ Lege Collection ${COLLECTION} an ...'; curl -s -X PUT ${QDRANT_URL}/collections/${COLLECTION} -H 'Content-Type: application/json' -d '{\"vectors\":{\"size\":${EMBED_SIZE},\"distance\":\"Cosine\"}}'; echo; echo '✔ Fertig.'; fi"

# --- (7) Punkte importieren ---
log "Importiere Punkte aus ${POINTS_FILE}"
cat "${POINTS_FILE}" | kubectl -n "${NAMESPACE}" run uploader --rm -i --restart=Never \
  --image=curlimages/curl:8.9.0 -- \
  sh -lc "cat >/tmp/points.json && curl -s -X PUT '${QDRANT_URL}/collections/${COLLECTION}/points?wait=true' -H 'Content-Type: application/json' --data @/tmp/points.json && echo && echo '✔ Upsert abgeschlossen.'"

# --- (8) Chatbot Deployment ---
log "Deploye/aktualisiere Chatbot (Image: ${IMAGE})"
kubectl -n "${NAMESPACE}" apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chatbot
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels: { app: chatbot }
  template:
    metadata:
      labels: { app: chatbot }
    spec:
      containers:
      - name: chatbot
        image: ${IMAGE}
        imagePullPolicy: IfNotPresent
        envFrom:
        - configMapRef:
            name: chatbot-config
        - secretRef:
            name: openai-secret
        workingDir: /app
        command: ["bash","-lc","python chatbot.py"]
        stdin: true
        tty: true
YAML

log "Warte auf Chatbot-Rollout"
kubectl -n "${NAMESPACE}" rollout status deploy/chatbot --timeout=120s

# --- (9) Tests ---
log "Kurztest: Erste Punkte abrufen"
kubectl -n "${NAMESPACE}" run curlbox --rm -i --restart=Never \
  --image=curlimages/curl:8.9.0 -- \
  sh -lc "curl -s -X POST '${QDRANT_URL}/collections/${COLLECTION}/points/scroll' -H 'Content-Type: application/json' -d '{\"limit\":3,\"with_payload\":true,\"with_vector\":false}' | sed -n '1,40p'"

log "Funktionstest: Eine Frage direkt im Chatbot-Pod ausführen"
POD="$(kubectl -n "${NAMESPACE}" get pods -l app=chatbot -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "${NAMESPACE}" exec "${POD}" -- bash -lc "cd /app && python - <<'PY'
from chatbot import OpenAI, embed_query, qdrant_search, answer_from_hits
QUESTION = ${TEST_QUESTION@Q}
print('Testfrage:', QUESTION)
client = OpenAI()
vec = embed_query(client, QUESTION)
hits = qdrant_search(vec)
try:
    print('Top-Scores:', [ round(h.get('score',0.0),3) for h in hits ])
except Exception:
    pass
print()
print(answer_from_hits(hits))
PY"

log "Fertig. Interaktive Nutzung (optional):"
echo "kubectl -n ${NAMESPACE} exec -it \"${POD}\" -- bash -lc 'cd /app && python chatbot.py'"
