import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
// ---------------------------------------------------------
// CONFIGURATION: ENTER YOUR THINGSPEAK DETAILS HERE
// ---------------------------------------------------------
const String CHANNEL_ID = "XXXXXX"; // e.g., 123456
const String READ_API_KEY = "XXXXXX"; // e.g., ABC12345
// ---------------------------------------------------------

void main() {
  runApp(const WeatherApp());
}

class WeatherApp extends StatelessWidget {
  const WeatherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'IoT Weather Station',
      // Define a "Fascinating" Dark Theme
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF1A1A2E), // Deep Navy
        cardColor: const Color(0xFF16213E), // Lighter Navy
        primaryColor: Colors.orangeAccent,
      ),
      home: const DashboardScreen(),
    );
  }
}

// Data Model to parse ThingSpeak JSON
class WeatherData {
  final DateTime time;
  final double temp;       // Field 1
  final double humidity;   // Field 2
  final double altitude;   // Field 3
  final double pressure;   // Field 4
  final double airQuality; // Field 5

  WeatherData({
    required this.time,
    required this.temp,
    required this.humidity,
    required this.altitude,
    required this.pressure,
    required this.airQuality,
  });

  factory WeatherData.fromJson(Map<String, dynamic> json) {
    return WeatherData(
      time: DateTime.parse(json['created_at']),
      // SAFELY PARSE ALL 5 FIELDS
      temp:       double.tryParse(json['field1'] ?? '0') ?? 0.0,
      humidity:   double.tryParse(json['field2'] ?? '0') ?? 0.0,
      altitude:   double.tryParse(json['field4'] ?? '0') ?? 0.0,
      pressure:   double.tryParse(json['field3'] ?? '0') ?? 0.0,
      airQuality: double.tryParse(json['field5'] ?? '0') ?? 0.0,
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<WeatherData> history = [];
  WeatherData? currentReading;
  bool isLoading = true;
  Timer? _timer;
  String errorMessage = "";

  // --- 1. ADD MQTT VARIABLES ---
  MqttServerClient? mqttClient;
  // CRITICAL: This topic MUST match the one in your ESP32 code exactly!
  final String mqttTopic = "myproject/weather/live";

  @override
  void initState() {
    super.initState();

    // Start ThingSpeak (History)
    fetchData();

    // --- 2. START MQTT (Live Updates) ---
    setupMqtt();

    // Auto-refresh history every 15 seconds
    _timer = Timer.periodic(const Duration(seconds: 15), (t) => fetchData());
  }

  @override
  void dispose() {
    _timer?.cancel();
    mqttClient?.disconnect(); // Good practice to disconnect
    super.dispose();
  }
  Future<void> fetchData() async {
    print("Fetching data...");

    final url = "https://api.thingspeak.com/channels/$CHANNEL_ID/feeds.json?api_key=$READ_API_KEY&results=20";

    try {
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final Map<String, dynamic> json = jsonDecode(response.body);
        final List<dynamic> feeds = json['feeds']; // Get the list of data

        if (feeds.isNotEmpty) {
          // CASE A: We have data! Show it.
          final List<WeatherData> data = feeds.map((e) => WeatherData.fromJson(e)).toList();
          setState(() {
            history = data;
            currentReading = data.last;
            isLoading = false;
            errorMessage = "";
          });
        } else {
          // CASE B: The Channel is Empty (THIS IS YOUR PROBLEM)
          setState(() {
            isLoading = false; // Stop the spinner!
            errorMessage = "Channel is Empty.\nTurn on your ESP32 to send data!";
          });
        }
      } else {
        setState(() {
          isLoading = false;
          errorMessage = "Server Error: ${response.statusCode}";
        });
      }
    } catch (e) {
      setState(() {
        isLoading = false;
        errorMessage = "Connection Failed: $e";
      });
    }
  }

  // --- 3. THE NEW MQTT ENGINE ---
  Future<void> setupMqtt() async {
    // Generate a random Client ID so HiveMQ doesn't kick us off
    String clientId = 'FlutterApp_' + DateTime.now().millisecondsSinceEpoch.toString();

    mqttClient = MqttServerClient('broker.hivemq.com', clientId);
    mqttClient!.port = 1883;
    mqttClient!.logging(on: false);
    mqttClient!.keepAlivePeriod = 20;
    mqttClient!.onDisconnected = () => print("MQTT Disconnected");

    try {
      await mqttClient!.connect();
    } catch (e) {
      print('MQTT Connection Failed: $e');
      mqttClient!.disconnect();
      return;
    }

    if (mqttClient!.connectionStatus!.state == MqttConnectionState.connected) {
      print('MQTT Connected Successfully!');

      // Subscribe to the topic
      mqttClient!.subscribe(mqttTopic, MqttQos.atMostOnce);

      // LISTEN for incoming data
      mqttClient!.updates!.listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
        final MqttPublishMessage recMess = c![0].payload as MqttPublishMessage;
        final String pt = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

        // We received data! Let's update the UI instantly.
        try {
          // Parse the JSON sent by ESP32: {"temp": 25.5, "hum": 60...}
          final Map<String, dynamic> liveData = jsonDecode(pt);

          setState(() {
            currentReading = WeatherData(
              time: DateTime.now(), // Use current time
              temp: double.tryParse(liveData['temp'].toString()) ?? 0.0,
              humidity: double.tryParse(liveData['hum'].toString()) ?? 0.0,
              pressure: double.tryParse(liveData['pres'].toString()) ?? 0.0,
              altitude: double.tryParse(liveData['alt'].toString()) ?? 0.0,
              airQuality: double.tryParse(liveData['aqi'].toString()) ?? 0.0,
            );

            // If we were loading, stop loading now because we have live data
            if(isLoading) isLoading = false;
          });
          print("Live Update Received: ${liveData['temp']}°C");

        } catch (e) {
          print("Error parsing MQTT JSON: $e");
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Weather Station"),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.show_chart, color: Colors.white),
            tooltip: "View All Charts",
            onPressed: () {
              // Navigate to the new screen, passing the current history data
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => DetailChartsScreen(history: history),
                ),
              );
            },
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator()) // Still loading? Show spinner.
          : errorMessage.isNotEmpty
          ? Center( // Error exists? Show Red Text.
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Text(
            errorMessage,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.redAccent, fontSize: 18),
          ),
        ),
      )
          : RefreshIndicator( // Success? Show Dashboard.
        onRefresh: fetchData,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. LIVE SENSOR CARDS
              const Text("Environment Status", style: TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 15),
              // ROW 1: Temp & Humidity
              Row(
                children: [
                  Expanded(child: _buildSensorCard("Temp", "${currentReading?.temp}°C", Icons.thermostat, Colors.orange)),
                  const SizedBox(width: 15),
                  Expanded(child: _buildSensorCard("Humidity", "${currentReading?.humidity}%", Icons.water_drop, Colors.blue)),
                ],
              ),
              const SizedBox(height: 15),
              // ROW 2: Pressure & Altitude
              Row(
                children: [
                  Expanded(child: _buildSensorCard("Pressure", "${currentReading?.pressure} hPa", Icons.speed, Colors.green)),
                  const SizedBox(width: 15),
                  Expanded(child: _buildSensorCard("Altitude", "${currentReading?.altitude} m", Icons.terrain, Colors.brown)),
                ],
              ),
              const SizedBox(height: 15),

// ROW 3: Air Quality (Full Width for Emphasis)
              _buildAirQualityCard(currentReading?.airQuality ?? 0.0),
              const SizedBox(height: 30),

// 2. THE HISTORY GRAPH (Keep this as is, or I can help you add tabs to switch graphs)
//               const Text("Temperature Trend", style: TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.bold)),
//               const SizedBox(height: 15),
//
//               Container(
//                 height: 300,
//                 padding: const EdgeInsets.only(right: 20, top: 20, bottom: 10),
//                 decoration: BoxDecoration(
//                   color: const Color(0xFF16213E),
//                   borderRadius: BorderRadius.circular(20),
//                 ),
//                 child: LineChart(
//                   LineChartData(
//                     gridData: const FlGridData(show: false),
//                     titlesData: const FlTitlesData(
//                       topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
//                       rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
//                       leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40)),
//                       bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
//                     ),
//                     borderData: FlBorderData(show: false),
//                     lineBarsData: [
//                       LineChartBarData(
//                         spots: history.asMap().entries.map((e) {
//                           return FlSpot(e.key.toDouble(), e.value.temp);
//                         }).toList(),
//                         isCurved: true,
//                         color: Colors.orange,
//                         barWidth: 4,
//                         belowBarData: BarAreaData(show: true, color: Colors.orange.withOpacity(0.2)),
//                         dotData: const FlDotData(show: false),
//                       ),
//                     ],
//                   ),
//                 ),
//               ),

              const SizedBox(height: 20),
              Center(child: Text("Last Update: ${DateFormat('h:mm:ss a').format(currentReading!.time)}", style: const TextStyle(color: Colors.grey))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSensorCard(String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF16213E),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 10, offset: const Offset(0, 5))],
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 40),
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(color: Colors.white60)),
          const SizedBox(height: 5),
          Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
        ],
      ),
    );
  }
}

Widget _buildAirQualityCard(double aqValue) {
  // Determine color based on pollution level
  Color statusColor = Colors.greenAccent;
  String statusText = "Good";

  if (aqValue > 100) {
    statusColor = Colors.redAccent;
    statusText = "Poor";
  } else if (aqValue > 50) {
    statusColor = Colors.orangeAccent;
    statusText = "Moderate";
  }

  return Container(
    width: double.infinity, // Full width
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: const Color(0xFF16213E),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: statusColor.withOpacity(0.5), width: 2), // Glow effect
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Air Quality (AQI)", style: TextStyle(color: Colors.white60)),
            const SizedBox(height: 5),
            Text("${aqValue.toInt()}", style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white)),
          ],
        ),
        Column(
          children: [
            Icon(Icons.cloud, color: statusColor, size: 40),
            Text(statusText, style: TextStyle(color: statusColor, fontWeight: FontWeight.bold)),
          ],
        )
      ],
    ),
  );
}

class ProfessionalChart extends StatelessWidget {
  final List<WeatherData> data;
  final double Function(WeatherData) getValue;
  final Color color;
  final String title;
  final String unit;

  const ProfessionalChart({
    super.key,
    required this.data,
    required this.getValue,
    required this.color,
    required this.title,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const Center(child: Text("No Data", style: TextStyle(color: Colors.white)));

    // Calculate Min/Max to auto-scale the graph nicely
    double minY = data.map((e) => getValue(e)).reduce((a, b) => a < b ? a : b);
    double maxY = data.map((e) => getValue(e)).reduce((a, b) => a > b ? a : b);

    // Add some "padding" to the top/bottom of the graph so the line doesn't touch the edge
    double buffer = (maxY - minY) * 0.2;
    if(buffer == 0) buffer = 5; // Prevent crash if flat line

    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header showing the "Current" (Last) Value prominently
          Text(title.toUpperCase(), style: const TextStyle(color: Colors.grey, fontSize: 12, letterSpacing: 1.5)),
          const SizedBox(height: 5),
          Row(
            children: [
              Text(
                  getValue(data.last).toStringAsFixed(1),
                  style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold)
              ),
              Text(" $unit", style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.w500)),
            ],
          ),
          const SizedBox(height: 30),

          // The Chart Container
          Expanded(
            child: Container(
              padding: const EdgeInsets.only(right: 20, top: 10, bottom: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF16213E), // Card background
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white10),
              ),
              child: LineChart(
                LineChartData(
                  minY: minY - buffer, // Auto-scale
                  maxY: maxY + buffer,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (value) => FlLine(color: Colors.white10, strokeWidth: 1),
                  ),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                        getTitlesWidget: (value, meta) => Text(
                          value.toInt().toString(),
                          style: const TextStyle(color: Colors.grey, fontSize: 10),
                        ),
                      ),
                    ),
                    bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                  lineTouchData: LineTouchData(
                    getTouchedSpotIndicator: (barData, spotIndexes) {
                      return spotIndexes.map((spotIndex) {
                        return TouchedSpotIndicatorData(
                          FlLine(color: Colors.white54, strokeWidth: 2, dashArray: [5, 5]), // Dotted Line
                          FlDotData(getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(radius: 6, color: color, strokeWidth: 2, strokeColor: Colors.white)),
                        );
                      }).toList();
                    },
                    touchTooltipData: LineTouchTooltipData(
                      // ✅ FIX: Use 'tooltipBgColor' instead of 'getTooltipColor'
                      tooltipBgColor: Colors.black87,
                      tooltipRoundedRadius: 8,
                      getTooltipItems: (touchedSpots) {
                        return touchedSpots.map((spot) {
                          return LineTooltipItem(
                            "${spot.y.toStringAsFixed(1)} $unit", // Show value with 1 decimal place
                            const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          );
                        }).toList();
                      },
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: data.asMap().entries.map((e) {
                        return FlSpot(e.key.toDouble(), getValue(e.value));
                      }).toList(),
                      isCurved: true,
                      curveSmoothness: 0.35, // Smooth curves
                      color: color,
                      barWidth: 3,
                      isStrokeCapRound: true,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        // Gradient Fade
                        gradient: LinearGradient(
                          colors: [color.withOpacity(0.3), color.withOpacity(0.0)],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

class DetailChartsScreen extends StatelessWidget {
  final List<WeatherData> history;

  const DetailChartsScreen({super.key, required this.history});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1A2E), // Deep Navy Background
        appBar: AppBar(
          title: const Text("Historical Trends", style: TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          // --- PROFESSIONAL TAB BAR ---
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(60),
            child: Container(
              height: 45,
              margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF16213E), // Darker background for the bar
                borderRadius: BorderRadius.circular(25),
              ),
              child: TabBar(
                isScrollable: true,
                indicator: BoxDecoration(
                  color: Colors.orangeAccent, // Bubble Style Indicator
                  borderRadius: BorderRadius.circular(25),
                ),
                labelColor: Colors.white, // Selected Text Color
                unselectedLabelColor: Colors.grey, // Unselected Text Color
                labelStyle: const TextStyle(fontWeight: FontWeight.bold),
                dividerColor: Colors.transparent, // Remove the ugly line
                tabs: const [
                  Tab(text: "  Temp  "),
                  Tab(text: "  Humidity  "),
                  Tab(text: "  Pressure  "),
                  Tab(text: "  Altitude  "),
                  Tab(text: "  Air Quality  "),
                ],
              ),
            ),
          ),
        ),
        body: TabBarView(
          children: [
            ProfessionalChart(data: history, getValue: (d) => d.temp, color: Colors.orange, title: "Temperature", unit: "°C"),
            ProfessionalChart(data: history, getValue: (d) => d.humidity, color: Colors.blue, title: "Humidity", unit: "%"),
            ProfessionalChart(data: history, getValue: (d) => d.pressure, color: Colors.green, title: "Pressure", unit: "hPa"),
            ProfessionalChart(data: history, getValue: (d) => d.altitude, color: Colors.brown, title: "Altitude", unit: "m"),
            ProfessionalChart(data: history, getValue: (d) => d.airQuality, color: Colors.redAccent, title: "Air Quality", unit: "AQI"),
          ],
        ),
      ),
    );
  }
}