# Console‑RAG‑Chatbot – Anleitung

Diese Datei erklärt **zwei Bash‑Skripte** und wie du sie nutzt:

- `build-deploy-chatbot.sh` – baut das Docker‑Image, erzeugt `points.json`, richtet Kubernetes‑Ressourcen ein (Qdrant + Chatbot) und testet die Installation.
- `cleanup-chatbot.sh` – räumt alles wieder auf (Kubernetes, temporäre Container) und kann auf Wunsch auch lokale Ordner löschen.

## 1) Voraussetzungen

- **Docker Desktop** mit **Kubernetes** aktiviert.
- **kubectl** im Pfad.
- **Internetverbindung**.
- Ein **OpenAI API‑Key** (wird beim Ausführen sicher abgefragt oder per Umgebungsvariable gesetzt).


## 2) Schnellstart

1. **Skripte ausführbar machen**
   ```bash
   chmod +x build-deploy-chatbot.sh cleanup-chatbot.sh
   ```

2. **Build & Deploy ausführen**  
   Du wirst nach dem OpenAI‑Key gefragt. Das Script erzeugt die Vektordatei `points.json` automatisch im Container (ohne Host‑Mount) und kopiert sie heraus.
   ```bash
   ./build-deploy-chatbot.sh
   ```

3. **Interaktiv testen (optional)**
   ```bash
   POD=$(kubectl -n rag-bot get pods -l app=chatbot -o jsonpath='{.items[0].metadata.name}')
   kubectl -n rag-bot exec -it "$POD" -- bash -lc 'cd /app && python chatbot.py'
   ```


## 3) Was `build-deploy-chatbot.sh` genau macht

1. **Build‑Kontext vorbereiten**  
   Legt bei Bedarf `./app/Dockerfile`, `./app/requirements.txt`, `./app/chatbot.py`, `./app/main.py` an (nur, wenn Dateien fehlen).

2. **Docker‑Image bauen**
   ```bash
   docker build -t console-chatbot:latest ./app
   ```

3. **`points.json` erzeugen – ohne Host‑File‑Sharing**  
   - Startet einen Container mit `main.py` und schreibt die Ausgabe nach **`/data/points.json`**.
   - Kopiert die Datei mit `docker cp` nach **`./output/points.json`**.
   - Vorteil: kein macOS „File Sharing“ nötig.
   ```bash
   # im Script enthalten (vereinfacht dargestellt)
   docker run --name points-gen-$$ -e OPENAI_API_KEY=... -e TOPIC=... console-chatbot:latest python main.py
   docker cp points-gen-1234:/data/points.json ./output/points.json
   docker rm -f points-gen-1234
   ```

4. **Kubernetes‑Ressourcen anlegen/aktualisieren**
   - **Namespace** (`rag-bot`).
   - **Secret** `openai-secret` (enthält nur den API‑Key).
   - **ConfigMap** `chatbot-config` (u. a. `QDRANT_URL=http://qdrant:6333`, `QDRANT_COLLECTION=thema_ki`, `EMBED_MODEL=text-embedding-3-small`).

5. **Qdrant deployen** (Deployment + Service) und auf **available** warten.

6. **Collection idempotent anlegen**  
   Legt die Collection nur an, wenn sie noch **nicht** existiert.

7. **Punkte importieren**  
   Schiebt `./output/points.json` per Qdrant‑HTTP‑API in die Collection.

8. **Chatbot deployen** und Rollout abwarten.

9. **Funktionstest**  
   - Scroll‑Test gegen Qdrant.
   - Beispiel‑Frage direkt im Chatbot‑Pod ausführen.


## 4) Wichtige Umgebungsvariablen (optional)

Du kannst das Verhalten vor dem Start anpassen. Alle Variablen haben sinnvolle Standardwerte.

```bash
# Auth
export OPENAI_KEY="sk-..."                 # wird sonst sicher abgefragt

# Inhalte / Embeddings
export TOPIC="Grundlagen der künstlichen Intelligenz"
export MAX_CHUNKS=3
export EMBED_MODEL="text-embedding-3-small"    # Dimension 1536

# Kubernetes
export NAMESPACE="rag-bot"
export COLLECTION="thema_ki"
export QDRANT_URL="http://qdrant:6333"
export MIN_SCORE="0.65"
export TOP_K="5"

# Image / Pfade
export IMAGE="console-chatbot:latest"
export APP_DIR="./app"
export POINTS_FILE="./output/points.json"
```

**Hinweis:** Der Chatbot antwortet **nur** mit Inhalten aus Qdrant. Wenn kein passender Treffer über dem Schwellwert liegt, meldet er „Ich weiß es nicht auf Basis der vorhandenen Daten.“


## 5) Typische Nutzungsschritte

### 5.1 Build & Deploy
```bash
./build-deploy-chatbot.sh
```

### 5.2 Punkte prüfen (kurzer Einblick)
```bash
kubectl -n rag-bot run curlbox --rm -i --restart=Never \
  --image=curlimages/curl:8.9.0 -- \
  sh -lc "curl -s -X POST 'http://qdrant:6333/collections/thema_ki/points/scroll' \
  -H 'Content-Type: application/json' -d '{\"limit\":3,\"with_payload\":true,\"with_vector\":false}' | sed -n '1,40p'"
```

### 5.3 Interaktiv fragen
```bash
POD=$(kubectl -n rag-bot get pods -l app=chatbot -o jsonpath='{.items[0].metadata.name}')
kubectl -n rag-bot exec -it "$POD" -- bash -lc 'cd /app && python chatbot.py'
```


## 6) Was `cleanup-chatbot.sh` macht

- Löscht **Kubernetes‑Ressourcen** (Standard: ganzen Namespace `rag-bot`).
- Entfernt temporäre **Docker‑Container** (`points-gen-*`).
- Optional: Entfernt das **Docker‑Image** und lokale Verzeichnisse.

### 6.1 Standard‑Cleanup
```bash
./cleanup-chatbot.sh
```

### 6.2 Selektiver Cleanup (Namespace behalten)
```bash
DELETE_NAMESPACE=false ./cleanup-chatbot.sh
```

### 6.3 Ordner mit entfernen
```bash
PURGE_APP_DIR=true PURGE_OUTPUT_DIR=true ./cleanup-chatbot.sh
```

### 6.4 Image ebenfalls löschen
```bash
PURGE_IMAGES=true ./cleanup-chatbot.sh
```

### 6.5 Trockenlauf (nur anzeigen)
```bash
DRY_RUN=true ./cleanup-chatbot.sh
```


## 7) Häufige Probleme und Lösungen

- **OpenAI‑Key fehlt oder ist ungültig**  
  Das Build‑Script fragt nach dem Key. Achte auf korrekte Eingabe ohne Leerzeichen.  
  Bei Bedarf:
  ```bash
  export OPENAI_KEY="sk-..."
  ./build-deploy-chatbot.sh
  ```

- **„Collection … already exists!“**  
  Das ist unkritisch. Die Anlage ist **idempotent**; die Collection bleibt bestehen.

- **„Vector dimension error: expected dim: 1536“**  
  Stelle sicher, dass `EMBED_MODEL="text-embedding-3-small"` zur Collection (Size **1536**) passt.

- **„mounts denied… File Sharing“ (macOS)**  
  Das Script nutzt **kein Host‑Mount**. Die `points.json` wird im Container erstellt und mit `docker cp` herauskopiert.

- **Qdrant nicht erreichbar**  
  Prüfe, ob der Service im Namespace läuft:
  ```bash
  kubectl -n rag-bot get all
  kubectl -n rag-bot logs deploy/qdrant
  ```

- **Chatbot ohne Treffer**  
  Prüfe, ob `points.json` importiert wurde (Scroll‑Test in Abschnitt 5.2).  
  Passe ggf. `MIN_SCORE` an oder erweitere das Thema/`MAX_CHUNKS`.


## 8) Sicherheit

- Der OpenAI‑Key wird als **Kubernetes‑Secret** gespeichert.  
- Teile deinen Key **nicht** in öffentlichen Repositories.
- Logs können Fehlermeldungen enthalten, aber keine Klartext‑Keys.


## 9) Aufräumen

Alles entfernen (inkl. Ordner):
```bash
PURGE_APP_DIR=true PURGE_OUTPUT_DIR=true PURGE_IMAGES=true ./cleanup-chatbot.sh
```


---

### Kurzübersicht der Skripte (Zusammenfassung)

- **build-deploy-chatbot.sh**: erstellt Build‑Dateien, baut Image, erzeugt `points.json` im Container, richtet Kubernetes ein, legt die Qdrant‑Collection an, importiert die Punkte und testet den Chatbot. (idempotent)  
- **cleanup-chatbot.sh**: löscht Ressourcen; optional auch Image und lokale Ordner.