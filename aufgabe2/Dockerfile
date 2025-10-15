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