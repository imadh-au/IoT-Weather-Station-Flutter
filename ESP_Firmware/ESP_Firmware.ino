#include <Wire.h>
#include <Adafruit_Sensor.h>
#include <Adafruit_BMP280.h>
#include <DHT.h>
#include <LiquidCrystal_I2C.h>
#include <WiFi.h>
#include <HTTPClient.h>
#include <PubSubClient.h>

// --- PIN DEFINITIONS ---
#define DHTPIN 4
#define DHTTYPE DHT22
#define MQ_PIN 34
#define LED_PIN 12

// --- WIFI SETTINGS ---
const char* ssid = "XXXXXX";//Wifi SSID
const char* password = "XXXXXX"; //Wifi Password

// --- THINGSPEAK SETTINGS ---
const char* thingSpeakServer = "http://api.thingspeak.com/update";
String thingSpeakApiKey = "XXXXXXX";

// --- MQTT SETTINGS (NEW) ---
const char* mqtt_server = "broker.hivemq.com"; // Free public broker
const char* mqtt_topic_live = "myproject/weather/live"; // Must match Flutter
WiFiClient espClient;
PubSubClient mqttClient(espClient);

// --- SENSORS & DISPLAY ---
DHT dht(DHTPIN, DHTTYPE);
Adafruit_BMP280 bmp;
LiquidCrystal_I2C lcd(0x27, 16, 2);

// --- TIMERS (The "No Delay" Logic) ---
unsigned long lastThingSpeakTime = 0;
unsigned long lastMqttTime = 0;
unsigned long lastLcdUpdate = 0;
int currentScreen = 0; // Tracks which screen to show

// --- GLOBAL VARIABLES ---
float temperature, humidity, pressure, altitude;
int airQuality, mqRaw;
String quality_txt, weatherStatus;

void setup() {
  Serial.begin(115200);
  delay(1000);

  // Initialize Sensors
  dht.begin();
  if (!bmp.begin(0x76)) {
    Serial.println("BMP280 not found!");
    while (1);
  }

  // Initialize LCD & LED
  lcd.init();
  lcd.backlight();
  lcd.clear();
  pinMode(LED_PIN, OUTPUT);

  // Connect to WiFi
  Serial.println("System Started");
  lcd.setCursor(0, 0);
  lcd.print("Connecting WiFi");

  WiFi.begin(ssid, password);
  int wifiAttempts = 0;
  while (WiFi.status() != WL_CONNECTED && wifiAttempts < 20) {
    delay(500);
    Serial.print(".");
    lcd.setCursor(wifiAttempts % 16, 1);
    lcd.print(".");
    wifiAttempts++;
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\nWiFi Connected!");
    lcd.clear();
    lcd.setCursor(0, 0);
    lcd.print("WiFi OK!");
    lcd.setCursor(0, 1);
    lcd.print(WiFi.localIP());
  } else {
    lcd.clear();
    lcd.print("WiFi Failed");
  }
  delay(2000);

  // Initialize MQTT
  mqttClient.setServer(mqtt_server, 1883);
}

void reconnectMqtt() {
  // Non-blocking reconnect loop
  if (!mqttClient.connected()) {
    String clientId = "ESP32Weather-" + String(random(0xffff), HEX);
    if (mqttClient.connect(clientId.c_str())) {
      Serial.println("MQTT Connected");
    }
  }
}

void loop() {
  // 1. Keep MQTT Alive (CRITICAL: Must run every loop)
  if (!mqttClient.connected()) reconnectMqtt();
  mqttClient.loop();

  unsigned long now = millis();

  // 2. Read Sensors (Continuously update variables)
  temperature = dht.readTemperature();
  humidity = dht.readHumidity();
  pressure = bmp.readPressure() / 100.0F;
  altitude = bmp.readAltitude(1013.25);
  
  mqRaw = analogRead(MQ_PIN);
  airQuality = map(mqRaw, 900, 2000, 0, 150);
  airQuality = constrain(airQuality, 0, 150);

  // Air Quality Logic
  if (airQuality <= 20) quality_txt = "GOOD";
  else if (airQuality <= 40) quality_txt = "NORMAL";
  else if (airQuality <= 60) quality_txt = "SLGT BAD";
  else quality_txt = "BAD";

  if (airQuality > 70) digitalWrite(LED_PIN, HIGH);
  else digitalWrite(LED_PIN, LOW);

  // Weather Status Logic
  if (humidity > 80 && temperature < 19) weatherStatus = "Rainy";
  else if (temperature > 30 && humidity < 50) weatherStatus = "Sunny";
  else weatherStatus = "Windy";

  // --- TASK A: SEND MQTT (FAST - Every 1 Second) ---
  if (now - lastMqttTime > 1000) {
    lastMqttTime = now;
    
    // Create JSON String manually
    String payload = "{";
    payload += "\"temp\": " + String(temperature, 1) + ",";
    payload += "\"hum\": " + String(humidity, 1) + ",";
    payload += "\"pres\": " + String(pressure, 1) + ",";
    payload += "\"alt\": " + String(altitude, 1) + ",";
    payload += "\"aqi\": " + String(airQuality);
    payload += "}";

    mqttClient.publish(mqtt_topic_live, payload.c_str());
    Serial.println(">> MQTT Live Update Sent");
  }

  // --- TASK B: SEND THINGSPEAK (SLOW - Every 20 Seconds) ---
  if (now - lastThingSpeakTime > 20000) {
    lastThingSpeakTime = now;
    sendToThingSpeak();
  }

  // --- TASK C: UPDATE LCD (Every 4 Seconds) ---
  if (now - lastLcdUpdate > 4000) {
    lastLcdUpdate = now;
    updateLcdScreen();
    currentScreen++;
    if (currentScreen > 3) currentScreen = 0; // Loop back to screen 0
  }
}

// --- HELPER FUNCTIONS ---

void updateLcdScreen() {
  lcd.clear();
  switch (currentScreen) {
    case 0: // Screen 1: Status
      lcd.setCursor(0, 0); lcd.print("Weather Pattern");
      lcd.setCursor(0, 1); lcd.print(weatherStatus);
      break;
    case 1: // Screen 2: Temp/Hum
      lcd.setCursor(0, 0); lcd.print("Temperature:" + String(temperature, 1) + "C");
      lcd.setCursor(0, 1); lcd.print("Humidity:" + String(humidity, 0) + "%");
      break;
    case 2: // Screen 3: Press/Alt
      lcd.setCursor(0, 0); lcd.print("Pressure:" + String(pressure, 0) + "hPa");
      lcd.setCursor(0, 1); lcd.print("Altitude:" + String(altitude, 0) + "m");
      break;
    case 3: // Screen 4: AQI
      lcd.setCursor(0, 0); lcd.print("AirQualityIn: " + String(airQuality));
      lcd.setCursor(0, 1); lcd.print(quality_txt);
      break;
  }
}

void sendToThingSpeak() {
  if (WiFi.status() == WL_CONNECTED && !isnan(temperature)) {
    HTTPClient http;
    String url = String(thingSpeakServer) + "?api_key=" + thingSpeakApiKey;
    url += "&field1=" + String(temperature, 1);
    url += "&field2=" + String(humidity, 1);
    url += "&field3=" + String(pressure, 1);
    url += "&field4=" + String(altitude, 1);
    url += "&field5=" + String(airQuality);

    http.begin(url);
    int httpCode = http.GET();
    http.end();
    
    if(httpCode == 200) Serial.println(">> ThingSpeak History Logged");
    else Serial.println(">> ThingSpeak Failed");
  }
}