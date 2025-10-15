# Docker-Compose-Aufgabe: Flask mit Gunicorn & Docker Compose

Diese Übung erweitert die bestehende Flask-Docker-App um **Gunicorn** (Produktionsserver) und **Docker Compose** (bequemer Start/Stop mehrerer Container).
---

## Voraussetzungen

- Bestehende Basis aus der vorherigen 1.Aufgabe (Flask-App in Docker).
- Docker Desktop / Docker Engine läuft.
- Optional: Docker Compose v2 (bei Docker Desktop bereits enthalten).

---

## Schritt 1 – `requirements.txt` für Gunicorn ergänzen

Füge **Gunicorn** hinzu (fixierte Version für Reproduzierbarkeit):

```txt
Flask==3.0.3
gunicorn==21.2.0
```

---

## Schritt 2 – `Dockerfile` auf Gunicorn umstellen

Ersetze den Startbefehl, damit statt des Flask-Dev-Servers **Gunicorn** verwendet wird.
(Weitere Best Practices bleiben wie gehabt: schlankes Image, Nicht-root-User, Caching durch Reihenfolge.)

```dockerfile
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 5000

# Sicherheit: Nicht als root laufen
RUN useradd -m appuser
USER appuser

# Gunicorn: 2 Worker, jeweils 2 Threads; bind an 0.0.0.0:5000
CMD ["gunicorn", "-w", "2", "--threads", "2", "-b", "0.0.0.0:5000", "app:app"]
```

**Warum Gunicorn?**
- Stabiler als der Flask-Dev-Server, besseres Concurrency-Handling.
- Einheitliches Logging, reproduzierbares Verhalten in Containern.

---

## Schritt 3 – Image neu bauen

```bash
docker build -t flask-demo:gunicorn .
```

---

## Schritt 4 – `docker-compose.yml` hinzufügen

Erzeuge eine Datei `docker-compose.yml` im Projektverzeichnis:

```yaml
version: "3.9"

services:
web:
build: .
image: flask-demo:compose
container_name: flask-web
ports:
- "5200:5000"
environment:
# Beispiel: hier könnte eine Konfiguration stehen, die von der App genutzt wird
- FLASK_ENV=production
restart: unless-stopped
```

**Erläuterung:**
- **web**: baut das Image aus dem lokalen Dockerfile und startet den Container.
- **ports**: macht den Service unter `http://localhost:5200` erreichbar.
- **restart**: automatischer Neustart bei Fehlern oder nach Reboot (optional).

---

## Schritt 6 – Starten & Stoppen mit Docker Compose

**Start (im Hintergrund):**
```bash
docker compose up -d
```

**Status prüfen:**
```bash
docker compose ps
```

**Test:**
```bash
curl -i http://localhost:5200
```

**Logs (laufend, ESC/STRG+C zum Verlassen der Log-Ansicht):**
```bash
docker compose logs -f
```

**Stoppen:**
```bash
docker compose down
```

**Hinweis:**
- `docker compose down` beendet den Container und gibt den Port frei.
- Die Ausgabe enthält in der Regel Zeilen wie „Stopping flask-web … done“ und „Removing network …“.

---

## Optional – Aufräumen & Neuaufbau-Kommandos

**Gestoppte Container, nicht benötigte Images & Layers entfernen:**
```bash
docker system prune -f
```

**Compose frisch bauen (z. B. nach Codeänderungen):**
```bash
docker compose build --no-cache
docker compose up -d
```

---

## Kurzübersicht der wichtigsten Befehle

**Bauen (einmalig oder nach Änderungen):**
```bash
docker build -t flask-demo:gunicorn .
```

**Direktlauf (ohne Compose):**
```bash
docker run -p 5200:5000 flask-demo:gunicorn
```

**Mit Compose:**
```bash
docker compose up -d
docker compose ps
docker compose logs -f
docker compose down
```

**Test:**
```bash
curl -i http://localhost:5200
```

## Erwartete `curl`-Ausgabe (Beispiel)

```
HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
...
<!doctype html>
<html lang="de">
<head>...
<body>
<main role="main">
<h1>Hallo, Welt!</h1>
...
```

---

## Fehlerbehebung (Gunicorn & Compose)

| Problem | Ursache | Lösung |
|---|---|---|
| `Address already in use` | Port 5200 belegt | Anderen Host-Port wählen, z. B. `-p 5300:5000` bzw. Compose: `5300:5000` |
| `ModuleNotFoundError: gunicorn` | `requirements.txt` nicht aktualisiert | `gunicorn` ergänzen, dann `docker build` erneut ausführen |
| `curl` zeigt Fehler | Container nicht gestartet | `docker compose ps` prüfen, ggf. `docker compose up -d` |
| App startet, aber 404 | Route falsch | In `app.py` Route `/` prüfen |
| Gunicorn Worker Crash | Syntaxfehler in App | `docker compose logs -f` lesen, Fehler beheben, neu bauen |
