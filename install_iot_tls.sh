#!/bin/bash

# ==============================================================================
# SCRIPT DE DÉPLOIEMENT IOT - VERSION 4 (Sécurisée HTTPS/TLS + HMAC)
# ==============================================================================

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

# --- 1. PROMPTS INTERACTIFS STYLISÉS ---
echo -e "${YELLOW}⚙️  CONFIGURATION DE LA BASE DE DONNÉES${NC}"
echo -n -e "${CYAN}▶ Nom de la base PostgreSQL ${NC}[ma_base_iot] : "
read DB_NAME
DB_NAME=${DB_NAME:-ma_base_iot}

echo -n -e "${CYAN}▶ Nom de l'utilisateur DB   ${NC}[user_iot] : "
read DB_USER
DB_USER=${DB_USER:-user_iot}

echo -n -e "${CYAN}▶ Mot de passe DB           ${NC}: "
read -s DB_PASS
echo -e "\n"

echo -e "${YELLOW}🔐 CONFIGURATION DE LA SÉCURITÉ${NC}"
echo -n -e "${CYAN}▶ Clé secrète HMAC (ESP32)  ${NC}[Projet_IoT_2026] : "
read SECRET_KEY
SECRET_KEY=${SECRET_KEY:-Projet_IoT_2026}
echo ""

# --- 1.5 DÉTECTION DE L'IP LOCALE ---
SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "${GREEN}▶ IP locale détectée : ${SERVER_IP}${NC}\n"

# Gestion adaptative de l'utilisateur (même si lancé avec sudo)
LINUX_USER=${SUDO_USER:-$USER}
PROJECT_DIR=$(pwd)
sudo chown -R $LINUX_USER:$LINUX_USER $PROJECT_DIR

echo -e "${GREEN}🚀 DÉMARRAGE DE L'INSTALLATION...${NC}\n"

# --- 2. INSTALLATION DES DÉPENDANCES SYSTÈME ---
echo -e "${YELLOW}📦 Installation de Docker, Python et dépendances...${NC}"
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg python3-pip python3-venv python3-dev libpq-dev

# Installation de Docker si non présent
if ! command -v docker &> /dev/null; then
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-compose
    sudo usermod -aG docker $LINUX_USER
fi

# --- 3. INSTALLATION DE NGINX ET GÉNÉRATION TLS ---
echo -e "${YELLOW}🛡️ CONFIGURATION DU REVERSE PROXY HTTPS (NGINX)...${NC}"
sudo apt-get install -y nginx

# Création silencieuse du certificat auto-signé
sudo mkdir -p /etc/ssl/private /etc/ssl/certs
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/iot_server.key \
  -out /etc/ssl/certs/iot_server.crt \
  -subj "/C=FR/ST=Nouvelle-Aquitaine/L=Poitiers/O=Projet IoT/CN=${SERVER_IP}" 2>/dev/null

# Création du fichier de configuration Nginx
sudo tee /etc/nginx/sites-available/iot_api > /dev/null << EOF
server {
    listen 443 ssl;
    server_name ${SERVER_IP};

    ssl_certificate /etc/ssl/certs/iot_server.crt;
    ssl_certificate_key /etc/ssl/private/iot_server.key;

    location /api/data {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

# Désactivation du site par défaut, activation de la nouvelle conf et redémarrage
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/iot_api /etc/nginx/sites-enabled/
sudo systemctl restart nginx
echo -e "${GREEN}✅ Nginx configuré et sécurisé sur le port 443 !${NC}\n"

# --- 4. CRÉATION DU DOCKER-COMPOSE ---
echo -e "${YELLOW}🐳 Génération de l'infrastructure Docker...${NC}"
cat << EOF > docker-compose.yml
version: '3.8'
services:
  postgres_db:
    image: postgres:15
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
    restart: always

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    depends_on:
      - postgres_db
    restart: always

volumes:
  pgdata:
EOF

# --- 5. CRÉATION DE L'API PYTHON (FLASK) ---
echo -e "${YELLOW}🐍 Génération de l'API Python sécurisée...${NC}"
cat << EOF > api.py
import os
import hmac
import hashlib
import json
import psycopg2
from flask import Flask, request, jsonify

app = Flask(__name__)
SECRET_KEY = b"${SECRET_KEY}"

def verify_hmac(payload_str, signature):
    computed = hmac.new(SECRET_KEY, payload_str.encode('utf-8'), hashlib.sha256).hexdigest()
    return hmac.compare_digest(computed, signature)

@app.route('/api/data', methods=['POST'])
def receive_data():
    signature = request.headers.get('X-HMAC-Signature')
    if not signature:
        return jsonify({"error": "Signature HMAC manquante"}), 401
    
    payload_str = request.get_data(as_text=True)
    if not verify_hmac(payload_str, signature):
        return jsonify({"error": "Signature HMAC invalide"}), 401

    data = request.json
    try:
        conn = psycopg2.connect(
            host="127.0.0.1", database="${DB_NAME}",
            user="${DB_USER}", password="${DB_PASS}"
        )
        cur = conn.cursor()
        
        # Création de la table dynamique (scalable) si elle n'existe pas
        cur.execute('''CREATE TABLE IF NOT EXISTS mesures (
            time TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
            mac VARCHAR(50), ip VARCHAR(50), modele VARCHAR(50),
            capteur VARCHAR(50), valeur DOUBLE PRECISION
        )''')
        
        cur.execute(
            "INSERT INTO mesures (mac, ip, modele, capteur, valeur) VALUES (%s, %s, %s, %s, %s)",
            (data.get('mac'), data.get('ip'), data.get('modele'), data.get('capteur'), data.get('valeur'))
        )
        conn.commit()
        cur.close()
        conn.close()
        return jsonify({"status": "succès"}), 201
    except Exception as e:
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    # ⚠️ Écoute uniquement sur Localhost (sécurisé derrière Nginx)
    app.run(host='127.0.0.1', port=5000)
EOF

cat << EOF > requirements.txt
Flask==3.0.0
psycopg2-binary==2.9.9
EOF

# --- 6. ENVIRONNEMENT VIRTUEL ET SERVICE SYSTEMD ---
echo -e "${YELLOW}⚙️  Configuration du service système en arrière-plan...${NC}"
python3 -m venv venv
./venv/bin/pip install -r requirements.txt

sudo tee /etc/systemd/system/iot_api.service > /dev/null << EOF
[Unit]
Description=API Backend IoT (Python)
After=network.target

[Service]
User=$LINUX_USER
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/venv/bin/python api.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable iot_api
sudo systemctl restart iot_api

# --- 7. LANCEMENT DES BASES DE DONNÉES ---
echo -e "${YELLOW}🚀 Démarrage de PostgreSQL et Grafana...${NC}"
sudo -u $LINUX_USER docker-compose up -d

echo -e "\n${CYAN}==================================================${NC}"
echo -e "${GREEN}🎉 INFRASTRUCTURE DÉPLOYÉE AVEC SUCCÈS !${NC}"
echo -e "${CYAN}==================================================${NC}"
echo -e "📊 Grafana      : http://${SERVER_IP}:3000"
echo -e "🔒 API (HTTPS)  : https://${SERVER_IP}/api/data"
echo -e "\n${YELLOW}⚠️  DERNIÈRE ÉTAPE POUR LE NŒUD IOT (C++) :${NC}"
echo -e "Pour que votre ESP32 fasse confiance à ce serveur TLS, vous devez copier"
echo -e "le certificat racine dans votre code source (rootCACertificate)."
echo -e "\n${CYAN}▶ Tapez cette commande pour afficher et copier le certificat :${NC}"
echo -e "cat /etc/ssl/certs/iot_server.crt\n"