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