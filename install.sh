#!/bin/bash

# ============================================================
#   Station Météo IoT — Script d'installation automatisé
#   PostgreSQL + Flask API (TLS/HMAC) + Grafana via Docker
# ============================================================

set -e

# ---------- Couleurs ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERREUR]${NC} $1"; exit 1; }

# --- BANNIÈRE ASCII ---
echo -e "${PURPLE}"
cat << "EOF"
  ___           _        _ _       _   _             
 |_ _|_ __ ___| |_ __ _| | | __ _| |_(_) ___  _ __  
  | || '_ \/ __| __/ _` | | |/ _` | __| |/ _ \| '_ \ 
  | || | | \__ \ || (_| | | | (_| | |_| | (_) | | | |
 |___|_| |_|___/\__\__,_|_|_|\__,_|\__|_|\___/|_| |_|
                                                     
  ____           _                                   
 |  _ \ ___  ___| |_ __ _ _ __ ___  ___              
 | |_) / _ \/ __| __/ _` | '__/ _ \/ __|             
 |  __/ (_) \__ \ || (_| | | |  __/\__ \             
 |_|   \___/|___/\__\__, |_|  \___||___/             
                 |___/                               
   ____            __                                
  / ___|_ __ __ _ / _| __ _ _ __   __ _              
 | |  _| '__/ _` | |_ / _` | '_ \ / _` |             
 | |_| | | | (_| |  _| (_| | | | | (_| |             
  \____|_|  \__,_|_|  \__,_|_| |_|\__,_|             
                                                     
EOF
echo -e "${NC}"
echo -e "${CYAN}==================================================${NC}"
echo -e "${GREEN}    Script de Déploiement Automatisé${NC}"
echo -e "${CYAN}==================================================${NC}\n"

# ============================================================
# 1. COLLECTE DES PARAMÈTRES
# ============================================================
echo -e "${BOLD}── Configuration ──────────────────────────────${NC}"

read -p "Adresse IP de cette VM (ex: 192.168.56.113) : " VM_IP
[[ -z "$VM_IP" ]] && err "L'IP est obligatoire."

read -s -p "Mot de passe PostgreSQL (meteo_user)       : " DB_PASS; echo
[[ -z "$DB_PASS" ]] && err "Le mot de passe PostgreSQL est obligatoire."

read -s -p "Mot de passe Grafana (admin)               : " GRAFANA_PASS; echo
[[ -z "$GRAFANA_PASS" ]] && err "Le mot de passe Grafana est obligatoire."

read -s -p "Clé secrète HMAC (doit correspondre ESP32) : " HMAC_KEY; echo
[[ -z "$HMAC_KEY" ]] && err "La clé HMAC est obligatoire."

read -p "Dossier d'installation [/opt/meteo]        : " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/opt/meteo}

echo ""
info "Récapitulatif :"
echo "  VM IP        : $VM_IP"
echo "  Dossier      : $INSTALL_DIR"
echo "  DB user      : meteo_user"
echo ""
read -p "Confirmer l'installation ? [o/N] : " CONFIRM
[[ "$CONFIRM" != "o" && "$CONFIRM" != "O" ]] && err "Installation annulée."

# ============================================================
# 2. MISE À JOUR SYSTÈME
# ============================================================
echo ""
echo -e "${BOLD}── Étape 1/6 — Mise à jour du système ─────────${NC}"
sudo apt update && sudo apt upgrade -y
ok "Système à jour"

# ============================================================
# 3. INSTALLATION DOCKER
# ============================================================
echo ""
echo -e "${BOLD}── Étape 2/6 — Installation de Docker ─────────${NC}"

if command -v docker &>/dev/null; then
    warn "Docker est déjà installé, étape ignorée."
else
    sudo apt install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    ok "Docker installé"
fi

# Ajout de l'utilisateur courant au groupe docker
if ! groups "$USER" | grep -q docker; then
    sudo usermod -aG docker "$USER"
    warn "Utilisateur ajouté au groupe docker (prendra effet à la prochaine session)"
fi

# ============================================================
# 4. CRÉATION DE LA STRUCTURE DU PROJET
# ============================================================
echo ""
echo -e "${BOLD}── Étape 3/6 — Création de la structure ────────${NC}"

sudo mkdir -p "$INSTALL_DIR/api"
sudo mkdir -p "$INSTALL_DIR/certs"
sudo chown -R "$USER:$USER" "$INSTALL_DIR"
ok "Dossiers créés : $INSTALL_DIR"

# ============================================================
# 5. GÉNÉRATION DU CERTIFICAT TLS
# ============================================================
echo ""
echo -e "${BOLD}── Étape 4/6 — Génération du certificat TLS ────${NC}"

if [[ -f "$INSTALL_DIR/certs/cert.pem" ]]; then
    warn "Certificat déjà présent, étape ignorée."
else
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$INSTALL_DIR/certs/key.pem" \
        -out    "$INSTALL_DIR/certs/cert.pem" \
        -days 365 \
        -subj "/C=FR/ST=Nouvelle-Aquitaine/L=Poitiers/O=Projet IoT/CN=${VM_IP}" \
        -addext "subjectAltName=IP:${VM_IP}" 2>/dev/null
    ok "Certificat généré pour $VM_IP (valable 365 jours)"
fi

echo ""
info "Contenu du certificat à copier dans le code ESP32 :"
echo -e "${YELLOW}"
cat "$INSTALL_DIR/certs/cert.pem"
echo -e "${NC}"

# ============================================================
# 6. GÉNÉRATION DES FICHIERS FLASK
# ============================================================
echo ""
echo -e "${BOLD}── Étape 5/6 — Création de l'API Flask ─────────${NC}"

# requirements.txt
cat > "$INSTALL_DIR/api/requirements.txt" << 'EOF'
flask
psycopg2-binary
EOF

# Dockerfile
cat > "$INSTALL_DIR/api/Dockerfile" << 'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
CMD ["python", "app.py"]
EOF

# app.py
cat > "$INSTALL_DIR/api/app.py" << PYEOF
import hmac as hmac_lib
import hashlib
import json
import psycopg2
import os
import logging
from flask import Flask, request, jsonify
import ssl

logging.basicConfig(level=logging.INFO)

app = Flask(__name__)

SECRET_KEY = os.environ.get("SECRET_KEY", "changeme")
DB_HOST    = os.environ.get("DB_HOST", "postgres")
DB_NAME    = os.environ.get("DB_NAME", "meteo")
DB_USER    = os.environ.get("DB_USER", "meteo_user")
DB_PASS    = os.environ.get("DB_PASS", "changeme")

TABLES = {
    "temperature": "mesure_temperature",
    "humidite":    "mesure_humidite",
    "pression":    "mesure_pression"
}

def get_db():
    return psycopg2.connect(
        host=DB_HOST, dbname=DB_NAME,
        user=DB_USER, password=DB_PASS
    )

def verifier_hmac(payload_brut, signature_recue):
    signature_calculee = hmac_lib.new(
        SECRET_KEY.encode(),
        payload_brut,
        hashlib.sha256
    ).hexdigest()
    return hmac_lib.compare_digest(signature_calculee, signature_recue)

@app.route("/api/data", methods=["POST"])
def recevoir_donnees():
    signature_recue = request.headers.get("X-HMAC-Signature", "")
    payload_brut    = request.get_data()

    if not verifier_hmac(payload_brut, signature_recue):
        return jsonify({"erreur": "Signature HMAC invalide"}), 403

    data    = json.loads(payload_brut)
    mac     = data.get("mac")
    ip      = data.get("ip")
    capteur = data.get("capteur")
    valeur  = data.get("valeur")

    if capteur not in TABLES:
        return jsonify({"erreur": "Capteur inconnu"}), 400

    try:
        conn = get_db()
        cur  = conn.cursor()

        cur.execute("SELECT id FROM esp_devices WHERE mac = %s", (mac,))
        row = cur.fetchone()
        if row:
            esp_id = row[0]
            cur.execute(
                "UPDATE esp_devices SET ip = %s, derniere_vue = NOW() WHERE id = %s",
                (ip, esp_id)
            )
        else:
            cur.execute(
                "INSERT INTO esp_devices (mac, ip) VALUES (%s, %s) RETURNING id",
                (mac, ip)
            )
            esp_id = cur.fetchone()[0]

        table = TABLES[capteur]
        cur.execute(
            f"INSERT INTO {table} (esp_id, valeur) VALUES (%s, %s)",
            (esp_id, valeur)
        )

        conn.commit()
        cur.close()
        conn.close()

        return jsonify({"status": "ok"}), 200

    except Exception as e:
        import traceback
        traceback.print_exc()
        return jsonify({"erreur": str(e)}), 500

if __name__ == "__main__":
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain("/certs/cert.pem", "/certs/key.pem")
    app.run(host="0.0.0.0", port=443, ssl_context=context)
PYEOF

ok "Fichiers Flask créés"

# ============================================================
# 7. GÉNÉRATION DU DOCKER-COMPOSE
# ============================================================
cat > "$INSTALL_DIR/docker-compose.yml" << COMPOSEEOF
services:
  postgres:
    image: postgres:16
    container_name: meteo_postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: meteo
      POSTGRES_USER: meteo_user
      POSTGRES_PASSWORD: ${DB_PASS}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"

  flask:
    build: ./api
    container_name: meteo_flask
    restart: unless-stopped
    environment:
      SECRET_KEY: "${HMAC_KEY}"
      DB_HOST: postgres
      DB_NAME: meteo
      DB_USER: meteo_user
      DB_PASS: ${DB_PASS}
    volumes:
      - ./certs:/certs:ro
    ports:
      - "443:443"
    depends_on:
      - postgres

  grafana:
    image: grafana/grafana:latest
    container_name: meteo_grafana
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_PASS}
    volumes:
      - grafana_data:/var/lib/grafana
    ports:
      - "3000:3000"
    depends_on:
      - postgres

volumes:
  postgres_data:
  grafana_data:
COMPOSEEOF

ok "docker-compose.yml généré"

# ============================================================
# 8. LANCEMENT DES CONTENEURS
# ============================================================
echo ""
echo -e "${BOLD}── Étape 6/6 — Lancement des conteneurs ────────${NC}"

cd "$INSTALL_DIR"
docker compose up -d --build
ok "Conteneurs démarrés"

# Attente que PostgreSQL soit prêt
info "Attente de PostgreSQL..."
sleep 8

# ============================================================
# 9. CRÉATION DES TABLES
# ============================================================
info "Création des tables PostgreSQL..."

docker exec -i meteo_postgres psql -U meteo_user -d meteo << 'SQLEOF'
CREATE TABLE IF NOT EXISTS esp_devices (
    id           SERIAL PRIMARY KEY,
    mac          VARCHAR(17) UNIQUE NOT NULL,
    ip           VARCHAR(45) NOT NULL,
    derniere_vue TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mesure_temperature (
    id       SERIAL PRIMARY KEY,
    esp_id   INT NOT NULL REFERENCES esp_devices(id),
    valeur   REAL NOT NULL,
    ts       TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mesure_humidite (
    id       SERIAL PRIMARY KEY,
    esp_id   INT NOT NULL REFERENCES esp_devices(id),
    valeur   REAL NOT NULL,
    ts       TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mesure_pression (
    id       SERIAL PRIMARY KEY,
    esp_id   INT NOT NULL REFERENCES esp_devices(id),
    valeur   REAL NOT NULL,
    ts       TIMESTAMP DEFAULT NOW()
);
SQLEOF

ok "Tables créées"

# ============================================================
# RÉCAPITULATIF FINAL
# ============================================================
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║        Installation terminée ✓           ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Grafana     → ${CYAN}http://${VM_IP}:3000${NC}  (admin / votre mot de passe)"
echo -e "  API Flask   → ${CYAN}https://${VM_IP}/api/data${NC}"
echo -e "  PostgreSQL  → ${CYAN}${VM_IP}:5432${NC}  (db: meteo / user: meteo_user)"
echo ""
echo -e "  ${YELLOW}N'oubliez pas de copier le certificat TLS affiché${NC}"
echo -e "  ${YELLOW}ci-dessus dans le code Arduino de votre ESP32.${NC}"
echo ""
echo -e "  Commandes utiles :"
echo "    docker logs -f meteo_flask       # logs API"
echo "    docker compose -f $INSTALL_DIR/docker-compose.yml down      # arrêt"
echo "    docker compose -f $INSTALL_DIR/docker-compose.yml up -d     # démarrage"
echo ""
