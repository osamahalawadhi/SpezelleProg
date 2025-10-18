# 6. Chatbot in Kubernetes (Docker Desktop Umgebung)

Dieser Leitfaden beschreibt, wie du den Qdrant-basierten Console-Chatbot aus den vorherigen Aufgaben
in **Kubernetes unter Docker Desktop** betreibst. 

---

## 1) Voraussetzungen

- Docker Desktop mit **Kubernetes aktiviert**
- `kubectl` installiert und mit Docker Desktop verbunden
- Qdrant-Datenbank (wird als Deployment im Cluster gestartet)
- Dein Chatbot-Image (aus vorheriger 5. Aufgabe)

---

## 2) Openai Secret anlegen

**Umgebungsvariable setzen:**
```bash
export OPENAI_KEY="your api key"
```
**Secret YAML File erstellen:**
```bash
cat <<YAML > secret-openai.yaml
apiVersion: v1
kind: Secret
metadata:
  name: secret-openai
  namespace: default
type: Opaque
stringData:
  OPENAI_API_KEY: "$OPENAI_KEY"
YAML
```

**Secret deployen:**
```bash
kubectl apply -f secret-openai.yaml
```

**Secret prüfen (Secrets sind base64 in k8s codiert):**
```bash
kubectl get secret secret-openai -o jsonpath='{.data.OPENAI_API_KEY}' | base64 --decode
```

---

## 3) Konfiguration anlegen (ConfigMap)

**Configmap YAML File erstellen:**
```bash
cat <<YAML > configmap-chatbot.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: configmap-chatbot
data:
  QDRANT_URL: "http://qdrant:6333"
  QDRANT_COLLECTION: "thema_ki"
  EMBED_MODEL: "text-embedding-3-small"
  MIN_SCORE: "0.65"
  TOP_K: "5"
YAML
```

**Configmap deployen:**
```bash
kubectl apply -f configmap-chatbot.yaml
```

**Configmap prüfen:**
```bash
kubectl describe cm configmap-chatbot
```
---

## 4) Qdrant Deployment und Service

**Deployment YAML File erstellen für Qdrant:**
```bash
cat <<YAML > deployment-qdrant.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qdrant
spec:
  replicas: 1
  selector:
    matchLabels: { app: qdrant }
  template:
    metadata:
      labels: { app: qdrant }
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
YAML
```

**YAML File erstellen für Qdrant Service:**
```bash
cat <<YAML > service-qdrant.yaml
apiVersion: v1
kind: Service
metadata:
  name: qdrant
spec:
  selector: { app: qdrant }
  ports:
  - name: http
    port: 6333
    targetPort: 6333
  - name: grpc
    port: 6334
    targetPort: 6334
YAML
```
**YAML Files deployen:**
```bash
kubectl apply -f deployment-qdrant.yaml 
kubectl apply -f service-qdrant.yaml
```

Warten, bis Qdrant bereit ist:
```bash
kubectl wait --for=condition=available deploy/qdrant --timeout=120s
```

Erwartete Erfolgsausgabe:
```bash
deployment.apps/qdrant condition met
```

**Qdrant befüllen:**
1. Kopiere den output Folder in dein aktuelles Verzeichnis
2. Dann führe folgendes aus
```bash
kubectl run qdrant-ensure-collection --rm -i --restart=Never \
  --image=curlimages/curl:8.9.0 --command -- \
  sh -lc 'set -e; if curl -sf http://qdrant:6333/collections/thema_ki >/dev/null; then echo "✔ Collection thema_ki existiert – überspringe Create."; else echo "Lege Collection thema_ki an ..."; curl -s -X PUT http://qdrant:6333/collections/thema_ki -H "Content-Type: application/json" -d "{\"vectors\":{\"size\":1536,\"distance\":\"Cosine\"}}"; echo; echo "✔ Fertig."; fi'
```
3. Anschliessend die Collection befüllen
```bash
export FILE="./output/points.json"
cat "$FILE" | kubectl run qdrant-ensure-uploader --rm -i --restart=Never \
  --image=curlimages/curl:8.9.0 -- \
  sh -lc "cat >/tmp/points.json && \
          curl -s -X PUT 'http://qdrant:6333/collections/thema_ki/points?wait=true' \
               -H 'Content-Type: application/json' \
               --data @/tmp/points.json && echo && echo '✔ Upsert abgeschlossen.'"
```
---

## 5) Chatbot Deployment

**YAML File erstellen UND ggf. Image anpassen (Nutze Image von 5. Aufgabe)!!!:**
```bash
cat <<'YAML' > deployment-chatbot.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chatbot
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
        image: 5aufgabe-chatbot:latest
        imagePullPolicy: Never
        envFrom:
        - configMapRef:
            name: configmap-chatbot
        - secretRef:
            name: secret-openai
        command: ["bash","-lc","python chatbot.py"]
        stdin: true
        tty: true
YAML
```

**YAML File für Chatbot deployen:**
```bash
kubectl apply -f deployment-chatbot.yaml 
```

Warten, bis Chatbot bereit ist:
```bash
kubectl wait --for=condition=available deploy/chatbot --timeout=120s
```

Erwartete Erfolgsausgabe:
```bash
deployment.apps/chatbot condition met
```
---

## 6) Interaktive Nutzung

Finde den Pod-Namen und starte den Chatbot:

```bash
export POD=$(kubectl get pods -l app=chatbot -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it "$POD" -- bash -lc 'python chatbot.py'
```

Beispielausgabe:

```
Console-Chatbot (Qdrant, nur Datenbankinhalte).
Frage eingeben und Enter drücken. Mit ':exit' beenden.
Collection: thema_ki @ http://qdrant:6333
Schwellwert (MIN_SCORE): 0.65 | Top-K: 5
------------------------------------------------------------
> was sind die ki anwendungsbereiche? 
> wie alt bist du?
```

Beenden: `:exit` oder `CTRL+C`

---

## 7) Diagnose und Tests

### Logs anzeigen
```bash
kubectl logs -l app=chatbot --tail=50 -f
```

### Verbindung zu Qdrant prüfen
```bash
kubectl run curlbox --rm -it --image=curlimages/curl:8.9.0 --   curl -s http://qdrant:6333/collections/thema_ki | head
```

### Config prüfen
```bash
kubectl exec deploy/chatbot -- env | egrep 'QDRANT|OPENAI|EMBED|MIN_SCORE|TOP_K'
```

---

## Hinweise
- Secrets werden in Kubernetes sicher gespeichert und nicht im Containerimage hinterlegt.
- Der Chatbot läuft interaktiv über `kubectl exec -it`.