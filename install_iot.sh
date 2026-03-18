#!/bin/bash

# --- COULEURS POUR L'INTERFACE ---
CYAN='\033[0;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
PURPLE='\033[1;35m'
NC='\033[0m' # No Color

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
echo -e "${GREEN}    Script de Déploiement Automatisé - V3.0${NC}"
echo -e "${CYAN}==================================================${NC}\n"

# --- 1. PROMPTS INTERACTIFS STYLISÉS ---
echo -e "${YELLOW}⚙️  CONFIGURATION DE LA BASE DE DONNÉES${NC}"
read -p "$(echo -e ${CYAN}▶ Nom de la base PostgreSQL ${NC}[ma_base_iot] : )" DB_NAME
DB_NAME=${DB_NAME:-ma_base_iot}

read -p "$(echo -e ${CYAN}▶ Nom de l'utilisateur DB   ${NC}[user_iot] : )" DB_USER
DB_USER=${DB_USER:-user_iot}

read -s -p "$(echo -e ${CYAN}▶ Mot de passe DB           ${NC}: )" DB_PASS
echo -e "\n"

echo -e "${YELLOW}🔐 CONFIGURATION DE LA SÉCURITÉ${NC}"
read -p "$(echo -e ${CYAN}▶ Clé secrète HMAC (ESP32)  ${NC}[Projet_IoT_2026] : )" SECRET_KEY
SECRET_KEY=${SECRET_KEY:-Projet_IoT_2026}
echo ""

# Gestion adaptative de l'utilisateur (même si lancé avec sudo)
LINUX_USER=${SUDO_USER:-$USER}
PROJECT_DIR=$(pwd)
sudo chown -R $LINUX_USER:$LINUX_USER $PROJECT_DIR

echo -e "${GREEN}🚀 DÉMARRAGE DE L'INSTALLATION...${NC}\n"

# --- 2. INSTALLATION DE DOCKER ---
echo -e "${YELLOW}[1/5]📦 Installation de Docker et dépendances...${NC}"
sudo apt update && sudo apt upgrade -y > /dev/null 2>&1
sudo apt install -y ca-certificates curl gnupg python3-venv > /dev/null 2>&1
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update > /dev/null 2>&1
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null 2>&1
sudo usermod -aG docker $LINUX_USER

# --- 3. CRÉATION DU DOSSIER PROJET ---
echo -e "${YELLOW}[2/5]📁 Préparation du répertoire projet...${NC}"
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR
touch mosquitto.conf

# --- 4. DOCKER COMPOSE ET POSTGRESQL ---
echo -e "${YELLOW}[3/5]🐳 Lancement des conteneurs (Postgres/Grafana/MQTT)...${NC}"
cat << EOF > docker-compose.yml
services:
  db:
    image: postgres:16
    container_name: postgres_db
    restart: always
    environment:
      POSTGRES_USER: $DB_USER
      POSTGRES_PASSWORD: $DB_PASS
      POSTGRES_DB: $DB_NAME
    ports:
      - "5432:5432"

  mosquitto:
    image: eclipse-mosquitto:latest
    container_name: mqtt_broker
    restart: always
    ports:
      - "1883:1883"
    volumes:
      - ./mosquitto.conf:/mosquitto/config/mosquitto.conf

  grafana:
    image: grafana/grafana
    container_name: grafana_ui
    restart: always
    ports:
      - "3000:3000"
    depends_on:
      - db
EOF

sudo docker compose up -d

echo -e "${YELLOW}      🗄️ Création de la table avec support Télémétrie Complète...${NC}"
sleep 5
sudo docker exec -i postgres_db psql -U $DB_USER -d $DB_NAME -c "
CREATE TABLE IF NOT EXISTS mesures (
    time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    capteur VARCHAR(50),
    valeur FLOAT,
    ip VARCHAR(15),
    mac VARCHAR(17),
    modele VARCHAR(50)
);"

# --- 5. L'API PYTHON ---
echo -e "${YELLOW}[4/5]🐍 Configuration de l'API Python Flask...${NC}"
python3 -m venv env_iot
source env_iot/bin/activate
pip install flask psycopg2-binary > /dev/null 2>&1

cat << 'EOF' > api_serveur.py
import hmac
import hashlib
import psycopg2
from flask import Flask, request, jsonify

app = Flask(__name__)

SECRET_KEY = "REPLACE_ME_SECRET"
DB_CONFIG = {
    "host": "127.0.0.1",
    "database": "REPLACE_ME_DB",
    "user": "REPLACE_ME_USER",
    "password": "REPLACE_ME_PASS",
    "port": "5432"
}

def verifier_signature(payload_brut, signature_recue):
    if not signature_recue: return False
    signature_calculee = hmac.new(SECRET_KEY.encode('utf-8'), payload_brut, hashlib.sha256).hexdigest()
    return hmac.compare_digest(signature_calculee, signature_recue)

@app.route('/api/data', methods=['POST'])
def receive_data():
    payload_brut = request.get_data() 
    signature_recue = request.headers.get('X-HMAC-Signature')

    if not verifier_signature(payload_brut, signature_recue):
        return jsonify({"erreur": "Non autorisé"}), 401

    try:
        data = request.get_json()
        capteur = data.get('capteur')
        valeur = data.get('valeur')
        ip_address = data.get('ip', '0.0.0.0')
        mac_address = data.get('mac', 'INCONNU')
        modele_carte = data.get('modele', 'Inconnu')

        if capteur and valeur is not None:
            conn = psycopg2.connect(**DB_CONFIG)
            cur = conn.cursor()
            cur.execute(
                "INSERT INTO mesures (capteur, valeur, ip, mac, modele) VALUES (%s, %s, %s, %s, %s)",
                (capteur, valeur, ip_address, mac_address, modele_carte)
            )
            conn.commit()
            cur.close()
            conn.close()
            return jsonify({"statut": "succès"}), 201
        else:
            return jsonify({"erreur": "Format de données invalide"}), 400
            
    except Exception as e:
        return jsonify({"erreur": "Erreur interne"}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOF

sed -i "s/REPLACE_ME_SECRET/$SECRET_KEY/g" api_serveur.py
sed -i "s/REPLACE_ME_DB/$DB_NAME/g" api_serveur.py
sed -i "s/REPLACE_ME_USER/$DB_USER/g" api_serveur.py
sed -i "s/REPLACE_ME_PASS/$DB_PASS/g" api_serveur.py

# --- 6. SERVICE SYSTEMD ---
echo -e "${YELLOW}[5/5]⚙️  Configuration du démon Systemd en arrière-plan...${NC}"
sudo bash -c "cat << EOF > /etc/systemd/system/iot_api.service
[Unit]
Description=API Flask pour Projet IoT
After=network.target

[Service]
User=$LINUX_USER
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/env_iot/bin/python3 $PROJECT_DIR/api_serveur.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable iot_api > /dev/null 2>&1
sudo systemctl restart iot_api

# --- 7. RÉCAPITULATIF FINAL ---
SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "\n${CYAN}==================================================${NC}"
echo -e "${GREEN}🎉 DÉPLOIEMENT TERMINÉ AVEC SUCCÈS !${NC}"
echo -e "${CYAN}==================================================${NC}"
echo -e "${YELLOW}🗄️  Base de données (PostgreSQL) :${NC}"
echo -e "   - Nom de la DB : ${GREEN}$DB_NAME${NC}"
echo -e "   - Utilisateur  : ${GREEN}$DB_USER${NC}"
echo -e "   - Port interne : 5432"
echo ""
echo -e "${YELLOW}📈 Interface Grafana :${NC}"
echo -e "   - URL d'accès  : ${GREEN}http://$SERVER_IP:3000${NC}"
echo -e "   - Login / Mdp  : admin / admin"
echo -e "${CYAN}==================================================${NC}"
echo -e "Pour plus d'informations, consultez le fichier ${GREEN}README.md${NC} dans le répertoire du projet."
echo -e "${CYAN}==================================================${NC}\n"