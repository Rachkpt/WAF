"""
Vuln-App — cible de test volontairement vulnérable pour valider le WAF.

⚠️ N'écoute que sur 127.0.0.1 : elle n'est jamais exposée directement,
uniquement à travers Nginx+ModSecurity (voir vuln-app/README.md).
Aucune sanitisation nulle part : c'est le but, un blocage prouve que
c'est le WAF qui a arrêté la requête, pas l'app elle-même.
"""
import os
import sqlite3
import subprocess

from flask import Flask, Response, redirect, request, send_file

app = Flask(__name__)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(BASE_DIR, "vuln.db")
FILES_DIR = os.path.join(BASE_DIR, "files")


def init_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, username TEXT, password TEXT)"
    )
    conn.execute(
        "INSERT INTO users (username, password) "
        "SELECT 'admin', 'admin123' WHERE NOT EXISTS (SELECT 1 FROM users)"
    )
    conn.commit()
    conn.close()


@app.route("/")
def index():
    return """
    <h1>Vuln-App — cible de test WAF</h1>
    <ul>
      <li><a href="/search?q=test">/search?q=</a> — XSS réfléchi</li>
      <li>POST /login (username, password) — injection SQL</li>
      <li><a href="/file?name=welcome.txt">/file?name=</a> — path traversal / LFI</li>
      <li><a href="/ping?host=127.0.0.1">/ping?host=</a> — injection de commande</li>
      <li><a href="/redirect?url=https://example.com">/redirect?url=</a> — open redirect</li>
      <li><a href="/fetch?url=http://127.0.0.1:5000/">/fetch?url=</a> — SSRF</li>
      <li>POST /upload (multipart "file") — upload sans validation</li>
      <li>POST /xml (corps XML) — XXE</li>
    </ul>
    """


# ---- XSS réfléchi : aucun échappement du paramètre ----
@app.route("/search")
def search():
    q = request.args.get("q", "")
    return f"<html><body>Résultats pour : {q}</body></html>"


# ---- Injection SQL : concaténation brute de la requête ----
@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "GET":
        return (
            '<form method="post">'
            'user:<input name="username"> pass:<input name="password" type="password">'
            "<button>go</button></form>"
        )
    username = request.form.get("username", "")
    password = request.form.get("password", "")
    conn = sqlite3.connect(DB_PATH)
    query = f"SELECT * FROM users WHERE username='{username}' AND password='{password}'"
    try:
        row = conn.execute(query).fetchone()
    except sqlite3.Error as e:
        return f"Erreur SQL : {e}", 500
    finally:
        conn.close()
    return "Connecté" if row else "Échec"


# ---- Path traversal / LFI : nom de fichier non validé ----
@app.route("/file")
def read_file():
    name = request.args.get("name", "welcome.txt")
    path = os.path.join(FILES_DIR, name)
    try:
        return send_file(path)
    except Exception as e:
        return f"Erreur : {e}", 404


# ---- Injection de commande : host injecté tel quel dans un shell ----
@app.route("/ping")
def ping():
    host = request.args.get("host", "127.0.0.1")
    result = subprocess.run(
        f"ping -c 1 {host}", shell=True, capture_output=True, text=True, timeout=5
    )
    return Response(result.stdout + result.stderr, mimetype="text/plain")


# ---- Open redirect : URL de destination non validée ----
@app.route("/redirect")
def open_redirect():
    url = request.args.get("url", "/")
    return redirect(url)


# ---- SSRF : le serveur va chercher l'URL demandée par le client ----
@app.route("/fetch")
def fetch():
    import requests

    url = request.args.get("url", "")
    try:
        r = requests.get(url, timeout=3)
        return Response(r.text, mimetype="text/plain")
    except Exception as e:
        return f"Erreur : {e}", 500


# ---- Upload sans aucune validation de type/extension ----
@app.route("/upload", methods=["POST"])
def upload():
    f = request.files.get("file")
    if not f:
        return "Aucun fichier", 400
    dest = os.path.join(FILES_DIR, f.filename)
    f.save(dest)
    return f"Fichier enregistré : {dest}"


# ---- XXE : résolution des entités externes activée volontairement ----
@app.route("/xml", methods=["POST"])
def xml_endpoint():
    from lxml import etree

    parser = etree.XMLParser(resolve_entities=True, no_network=False)
    try:
        tree = etree.fromstring(request.data, parser)
        return Response(etree.tostring(tree), mimetype="application/xml")
    except Exception as e:
        return f"Erreur : {e}", 400


if __name__ == "__main__":
    os.makedirs(FILES_DIR, exist_ok=True)
    welcome = os.path.join(FILES_DIR, "welcome.txt")
    if not os.path.exists(welcome):
        with open(welcome, "w") as fh:
            fh.write("Bienvenue - ceci est un fichier de test.\n")
    init_db()
    app.run(host="127.0.0.1", port=5000)
