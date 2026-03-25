#include <Wire.h>
#include <Adafruit_BMP280.h>
#include <DHT.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <mbedtls/md.h>
#include <WiFiClientSecure.h>

#define DHTPIN 2
#define DHTTYPE DHT11
#define SDA_PIN 6
#define SCL_PIN 7

const char* ssid = "ssid-wifi";
const char* password = "mdp-wifi";
const char* serverUrl = "https://ip-du-serveur/api/data";

const char* secretKey = "clé-hmac"; 

const char* rootCACertificate = \
"-----BEGIN CERTIFICATE-----\n"
"MIIDyDCCArCgAwIBAgIUeg4EjCRi11cPUxPeNtFJ1iYvhsswDQYJKoZIhvcNAQEL\n"
"..."
"vaXTGYBdV+Pt5hZv\n"
"-----END CERTIFICATE-----\n";


Adafruit_BMP280 bmp; 
DHT dht(DHTPIN, DHTTYPE);

String calculerSignature(String payload) {
  byte hmacResult[32];
  mbedtls_md_context_t ctx;
  mbedtls_md_init(&ctx);
  mbedtls_md_setup(&ctx, mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), 1);
  mbedtls_md_hmac_starts(&ctx, (const unsigned char *) secretKey, strlen(secretKey));
  mbedtls_md_hmac_update(&ctx, (const unsigned char *) payload.c_str(), payload.length());
  mbedtls_md_hmac_finish(&ctx, hmacResult);
  mbedtls_md_free(&ctx);
  String signature = "";
  for(int i = 0; i < 32; i++) { char hex[3]; sprintf(hex, "%02x", hmacResult[i]); signature += hex; }
  return signature;
}

void envoyer(String capteur, float valeur) {
    if (isnan(valeur)) valeur = -99.0; 
    
    String ip = WiFi.localIP().toString();
    String mac = WiFi.macAddress();
    String modele = "XIAO ESP32-C3";
    
    String payload = "{\"mac\":\"" + mac + "\", \"ip\":\"" + ip + "\", \"modele\":\"" + modele + "\", \"capteur\":\"" + capteur + "\", \"valeur\":" + String(valeur, 1) + "}";
    
    String signature = calculerSignature(payload);
    
    WiFiClientSecure client;
    client.setCACert(rootCACertificate);
    
    HTTPClient http;
    http.begin(client, serverUrl);
    
    http.addHeader("Content-Type", "application/json");
    http.addHeader("X-HMAC-Signature", signature);
    
    int httpResponseCode = http.POST(payload);
    
    if (httpResponseCode > 0) {
        Serial.print("✅ Données chiffrées (TLS) envoyées : ");
        Serial.println(payload);
    } else {
        Serial.print("❌ Erreur TLS/HTTP. Code : ");
        Serial.println(httpResponseCode);
    }
    
    http.end();
}

void setup() {
  Serial.begin(115200);

  pinMode(3, OUTPUT); digitalWrite(3, HIGH); 
  pinMode(4, OUTPUT); digitalWrite(4, HIGH);
  pinMode(5, OUTPUT); digitalWrite(5, HIGH);
  delay(2000); 

  Wire.begin(SDA_PIN, SCL_PIN);

  if (!bmp.begin(0x76) && !bmp.begin(0x77)) {
    Serial.println("❌ BMP280 non détecté");
  }

  dht.begin();

  WiFi.begin(ssid, password);
  while (WiFi.status() != WL_CONNECTED) { delay(500); }
}

void loop() {
  if (WiFi.status() == WL_CONNECTED) {
    float p = bmp.readPressure() / 100.0F;
    envoyer("pression", p);
    delay(2000);
    
    float t = dht.readTemperature();
    if (isnan(t)) t = bmp.readTemperature();
    envoyer("temperature", t);
    delay(2000);

    float h = dht.readHumidity();
    envoyer("humidite", h);
  }
  delay(15000); 
}