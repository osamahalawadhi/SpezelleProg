from flask import Flask, Response

app = Flask(__name__)

@app.route("/")
def home():
    html = """
    <!doctype html>
    <html lang="de">
      <head>
        <meta charset="utf-8">
        <title>Flask Docker Demo</title>
      </head>
      <body>
        <main role="main">
          <h1>Hallo, Welt!</h1>
          <p>Diese Nachricht stammt aus einer Flask-Anwendung, die in einem Docker-Container läuft.</p>
        </main>
      </body>
    </html>
    """
    return Response(html, mimetype="text/html")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)