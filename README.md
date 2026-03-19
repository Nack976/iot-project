# 🌤️ Station Météo IoT - XIAO ESP32-C3

Ce projet déploie une infrastructure complète de collecte, sécurisation et visualisation de données météorologiques (Température et Pression) issues d'un microcontrôleur Seeed Studio XIAO ESP32-C3.

## 🏗️ Architecture du Projet

* **Hardware :** XIAO ESP32-C3 + Capteur SEN-KY052 (BMP280) + DHT11
* **Sécurité :** Authentification des messages par signature HMAC-SHA256
* **Backend :** API Python (Flask) sous Systemd
* **Base de données :** PostgreSQL (conteneur Docker)
* **Visualisation :** Grafana (conteneur Docker)

---

## 🚀 Installation Automatisée

Un script de déploiement est fourni pour installer toute l'infrastructure (Docker, Base de données, API, Systemd) sur une machine Linux vierge (Ubuntu/Debian). En clonant ce dépôt, vous conservez également cette documentation en local sur votre serveur.

```bash
# 1. Entrer dans le dossier système /opt
cd /opt

# 2. Cloner le dépôt (sudo est requis car /opt est protégé)
sudo git clone https://github.com/Nack976/iot-project.git

# 3. Entrer dans le dossier du projet
cd iot-project

# 4. Donner les droits d'exécution au script
sudo chmod +x install_iot.sh

# 5. Lancer l'installation
sudo ./install_iot.sh

## Commandes SQL pour créer les dashboards

** Pression atmosphérique **

SELECT
  time AS "time",
  valeur AS "Pression (hPa)"
FROM mesures
WHERE
  capteur = 'pression' 
  AND $__timeFilter(time)
ORDER BY time ASC;

** Température **

SELECT
  time AS "time",
  valeur AS "Température (°C)"
FROM mesures
WHERE
  capteur = 'temperature' 
  AND $__timeFilter(time)
ORDER BY time ASC;

** Humidité **

SELECT
  time AS "time",
  valeur AS "Humidité (%)"
FROM mesures
WHERE
  capteur = 'humidite' 
  AND $__timeFilter(time)
ORDER BY time ASC;

** Informations sur la station météo **

SELECT 
  mac AS "Adresse MAC (Identifiant unique)",
  modele AS "Modèle de Nœud",
  ip AS "Adresse IP Locale",
  MAX(time) AS "Dernière communication"
FROM mesures
WHERE mac != 'INCONNU'
GROUP BY mac, modele, ip
ORDER BY "Dernière communication" DESC;