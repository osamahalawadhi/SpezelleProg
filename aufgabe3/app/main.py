import json
from datetime import datetime, timezone
from slugify import slugify
from openai import OpenAI

# --- Feste Werte (hier direkt anpassen) ---
OPENAI_API_KEY = "dein_neuer_key"
TOPIC = "Grundlagen der künstlichen Intelligenz"
MAX_CHUNKS = 3
EMBED_MODEL = "text-embedding-3-small"
GEN_MODEL = "gpt-4o-mini"
OUT_PATH = "/data/points.json"
# ------------------------------------------

def utcnow_iso():
    return datetime.now(timezone.utc).isoformat()

def gen_chunks(client: OpenAI, topic: str, max_chunks: int = 3):
    """
    Erstellt kurze inhaltliche Abschnitte (Chunks) zu einem Thema über die ChatGPT-API.
    """
    system = (
        "Erzeuge prägnante, faktenbasierte Textabschnitte (Chunks) für ein Thema. "
        "Jeder Chunk 2–4 Sätze, klare Sprache. Keine Aufzählungslisten, kein Marketing."
    )
    user = (
        f"Thema: {topic}\n"
        f"Erzeuge {max_chunks} Chunks. Gib ein JSON-Array zurück, "
        f"mit Objekten: title, content, tags (Array kurzer Stichworte)."
    )
    resp = client.chat.completions.create(
        model=GEN_MODEL,
        messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
        temperature=0.2,
        max_tokens=800
    )
    text = resp.choices[0].message.content.strip()
    start = text.find("[")
    end = text.rfind("]")
    if start == -1 or end == -1:
        raise ValueError("Antwort enthält kein JSON-Array.")
    arr_text = text[start:end + 1]
    data = json.loads(arr_text)
    return data[:max_chunks]

def embed_texts(client: OpenAI, texts):
    """
    Erstellt Embeddings (Vektoren) für Texte mit dem OpenAI-Embedding-Modell.
    """
    resp = client.embeddings.create(model=EMBED_MODEL, input=texts)
    return [item.embedding for item in resp.data]

def main():
    print(f"Thema: {TOPIC}")
    print(f"Erzeuge bis zu {MAX_CHUNKS} Chunks ...")

    client = OpenAI(api_key=OPENAI_API_KEY)

    # 1) Chunks erzeugen
    chunks = gen_chunks(client, TOPIC, max_chunks=MAX_CHUNKS)
    contents = [c.get("content", "") for c in chunks]
    vectors = embed_texts(client, contents)

    # 2) Qdrant-Points aufbauen
    created_at = utcnow_iso()
    doc_id = f"doc-{slugify(TOPIC) or 'topic'}"
    points = []
    for i, (chunk, vec) in enumerate(zip(chunks, vectors), start=1):
        point = {
            "id": i,
            "vector": vec,
            "payload": {
                "title": chunk.get("title", f"Chunk {i}"),
                "content": chunk.get("content", ""),
                "tags": chunk.get("tags", []),
                "language": "de",
                "source": f"generated:{doc_id}",
                "doc_id": doc_id,
                "chunk_id": i,
                "chunk_count": len(chunks),
                "created_at": created_at,
                "topic": TOPIC
            }
        }
        points.append(point)

    # 3) JSON-Datei schreiben
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump({"points": points}, f, ensure_ascii=False, indent=2)

    print("Fertig.")
    print("Datei gespeichert unter:", OUT_PATH)
    print("Anzahl Punkte:", len(points))
    print("Modell:", EMBED_MODEL)

if __name__ == "__main__":
    main()

