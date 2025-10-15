# 4. Aufgabe: `points.json` in Qdrant importieren (Upsert per REST-API)

Ziel: Die zuvor erzeugte Datei `output/points.json` in eine Qdrant-Collection importieren.  
Es wird gezeigt, wie Qdrant per Docker gestartet, eine passende Collection erstellt und die Daten per `upsert` geladen werden.

---

## Voraussetzungen

- Docker Desktop oder Docker Engine
- Vorhandene Datei: `output/points.json` (aus der vorherigen 3.Aufgabe)
- Standard-Ports: `6333` (HTTP), `6334` (gRPC)

---

## 1) Projektstruktur

Lege in einem neuen Ordner z. B. `4_Aufgabe/` diese Dateien an:

```
4_Aufgabe/
├─ docker-compose.yml
```

Stelle sicher, dass die Datei `output/points.json` **aus der vorherigen 3. Aufgabe** erreichbar ist (z. B. per absolutem Pfad oder indem du sie in diesen Ordner kopierst).

---

## 2) Qdrant mit Docker Compose starten

`docker-compose.yml`
```yaml
services:
  qdrant:
    image: qdrant/qdrant:latest
    container_name: qdrant
    ports:
      - "6333:6333"   # REST
      - "6334:6334"   # gRPC
    volumes:
      - qdrant_storage:/qdrant/storage
    restart: unless-stopped

volumes:
  qdrant_storage:
```

**Starten:**
```bash
docker compose up -d
```

**Prüfen, ob Qdrant läuft:**
```bash
curl -s http://localhost:6333/ | jq
```
Erwartung (Beispielauszug):
```
{
  "title": "qdrant - vector search engine",
  "version": "..."
}
```

---

## 3) Collection erstellen

Die Embeddings aus der vorherigen Aufgabe wurden mit einem Modell erzeugt, das **1536** Dimensionen liefert (`text-embedding-3-small`).  
Erzeuge eine Collection mit passender Vektorgröße und Cosine-Distanz.

**Collection-Name wählen:** Stelle einen kurzen, sprechenden Namen ein, z. B. `thema_ki`.

**Anlegen:**
```bash
curl -X PUT "http://localhost:6333/collections/thema_ki" \
  -H "Content-Type: application/json" \
  -d '{
        "vectors": {
          "size": 1536,
          "distance": "Cosine"
        }
      }'
```

**Prüfen:**
```bash
curl -s "http://localhost:6333/collections/thema_ki" | jq
```

---

## 4) `points.json` hochladen (Upsert)

Wenn `output/points.json` im aktuellen Ordner liegt:

```bash
curl -X PUT "http://localhost:6333/collections/thema_ki/points?wait=true" \
  -H "Content-Type: application/json" \
  --data @output/points.json
```

Erwartete Antwort (verkürzt):
```
{"result":{"operation_id":...,"status":"completed"},"status":"ok","time":...}
```

**Hinweis:**  
- `--data @output/points.json` liest die Datei lokal ein.  
- `?wait=true` wartet, bis das Einfügen abgeschlossen ist.

---

## 5) Daten sichten

**Erste Punkte scrollen (mit Payload):**
```bash
curl -X POST "http://localhost:6333/collections/thema_ki/points/scroll" \
  -H "Content-Type: application/json" \
  -d '{"limit": 3, "with_payload": true, "with_vector": false}'
```

**Punktanzahl zählen (einfacher Check):**
```bash
curl -s "http://localhost:6333/collections/thema_ki" | jq '.result.vectors_count // .result.points_count'
```

> Hinweis: Je nach Qdrant-Version kann das Zählfeld variieren. Alternativ kann man über `scroll` seitenweise zählen.

---

## 6) Beispielabfrage (semantische Suche)

**Filter-Beispiel (nach Topic):**
```bash
curl -X POST "http://localhost:6333/collections/thema_ki/points/scroll" \
  -H "Content-Type: application/json" \
  -d '{
        "limit": 3,
        "with_payload": true,
        "filter": {
          "must": [
            {"key": "topic", "match": {"value": "Grundlagen der künstlichen Intelligenz"}}
          ]
        }
      }'
```

---

## 7) Stoppen und Entfernen

**Stoppen:**
```bash
docker compose down
```

**Daten behalten:**  
Der Storage liegt in `./qdrant_storage`. Wenn du alles neu starten willst, lass den Ordner bestehen.  
Wenn du frisch beginnen möchtest, lösche den Ordner:

```bash
rm -rf qdrant_storage
```

---

## 8) Häufige Fehler

| Problem | Ursache | Lösung |
|---|---|---|
| Collection verweigert Upsert | Vektorgröße passt nicht | Collection mit richtiger `size` (z. B. 1536) anlegen |
| Upsert-Fehler 400/422 | JSON-Struktur fehlerhaft | Sicherstellen, dass `{"points": [ ... ]}` vorliegt |
| Keine Daten beim Scroll | Falscher Collection-Name | Namen prüfen (`/collections/{name}/points/scroll`) |
| Ports belegt | Anderer Dienst nutzt 6333/6334 | Compose stoppen oder alternative Ports mappen |

---