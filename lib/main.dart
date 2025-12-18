import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fuel_consumption_calculator/obd_service.dart';

void main() {
  runApp(const FuelTripApp());
}

class FuelTripApp extends StatelessWidget {
  const FuelTripApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fuel Trip Calculator',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const TripHomePage(),
    );
  }
}

class TripHomePage extends StatefulWidget {
  const TripHomePage({super.key});
  @override
  State<TripHomePage> createState() => _TripHomePageState();
}

class _TripHomePageState extends State<TripHomePage> {
  final ObdService _obdService = ObdService();
  List<BluetoothDevice> _pairedDevices = [];
  String _obdData = '';
  bool connected = false;
  BluetoothDevice? obdDevice;
  StreamSubscription? scanSub;
  Future<void> _getPairedDevices() async {
    final devices = await _obdService.getPairedDevices();
    setState(() {
      _pairedDevices = devices;
    });
  }

  // Live data
  double rpm = 0, mapKpa = 0, iatK = 0, eqRatio = 1.0, fuel = 0;
  List<FlSpot> fuelPoints = [];
  double timeSec = 0;
  Timer? timer;
  Timer? _tripTimer;
  final List<List<dynamic>> _samples = []; // time,rpm,map,iatK,fuel

  // Config
  double volEff = 85, engDisp = 2.0;

  // --- FUEL FORMULA ---
  double calcFuel(double rpm, double mapKpa, double iatK, double eqRatio) {
    if (iatK <= 0) return 0; // Avoid division by zero or invalid temp

    // MAF (Mass Air Flow) calculation using the speed-density equation.
    // MAF (g/s) = (RPM * MAP[kPa] * VolumetricEfficiency[%] * EngineDisplacement[L]) / (IntakeAirTemp[K] * Constant)
    // The constant depends on the gas constant for air and unit conversions.
    // A commonly used derived constant for these units is ~3444
    final double maf = (rpm * mapKpa * volEff * engDisp) / (iatK * 3444);

    // Air-to-Fuel Ratio (AFR) for gasoline is approximately 14.7
    const double afr = 14.7;
    final double fuelGramsPerSec = maf / (afr * eqRatio);

    // Density of gasoline is approximately 0.74 g/mL
    const double fuelDensity = 0.74;
    final double fuelMlPerSec = fuelGramsPerSec / fuelDensity;

    return fuelMlPerSec;
  }

  Future<void> _showDeviceSelectionDialog() async {
    await _getPairedDevices();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Select OBD2 Device'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              itemCount: _pairedDevices.length,
              itemBuilder: (context, index) {
                final device = _pairedDevices[index];
                return ListTile(
                  title: Text(device.name ?? "Unknown"),
                  subtitle: Text(device.address),
                  onTap: () async {
                    Navigator.of(context).pop();
                    await _obdService.connect(device);
                    setState(() {
                      connected = true;
                      obdDevice = device;
                    });
                    startTrip();
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<bool> requestPermissions() async {
    var scanStatus = await Permission.bluetoothScan.request();
    var connectStatus = await Permission.bluetoothConnect.request();
    var locationStatus = await Permission.location.request();
    if (mounted) {
      if (!scanStatus.isGranted ||
          !connectStatus.isGranted ||
          !locationStatus.isGranted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                "Bluetooth and location permissions are required for OBD2 scanning.")));
        return false;
      }
    }
    return true;
  }

  Future<void> startScan() async {
    if (!await requestPermissions()) return;
    await _showDeviceSelectionDialog();
  }

  void startTrip() {
    fuelPoints.clear();
    _samples.clear();
    timeSec = 0;

    _obdService.startListening((data) {
      final parts = data.split(':');
      if (parts.length != 2) return;

      final pid = parts[0].trim();
      final val = double.tryParse(parts[1].trim());
      if (val == null) return;

      setState(() {
        switch (pid) {
          case '01 0C':
            rpm = val;
            break;
          case '01 0B':
            mapKpa = val;
            break;
          case '01 0F':
            iatK = (val + 273.15); // if you want Kelvin
            break;
        }
      });
    });

    _tripTimer?.cancel();
    _tripTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        timeSec += 1;

        fuel = _obdService.obd2.fFuel(rpm, mapKpa, iatK);

        fuelPoints.add(FlSpot(timeSec, fuel));
        _samples.add([timeSec, rpm, mapKpa, iatK, fuel]);

        if (fuelPoints.length > 600) fuelPoints.removeAt(0);
      });
    });
  }


  void stopTrip() async {
    _tripTimer?.cancel();
    _tripTimer = null;

    _obdService.stopListening(obdDevice!);
    setState(() => connected = false);

    await saveCsv();
  }


  Future<void> saveCsv() async {
    final dir = await getApplicationDocumentsDirectory();
    final file =
        File('${dir.path}/trip_${DateTime.now().millisecondsSinceEpoch}.csv');
    // final data = [
    //   ['Time (s)', 'RPM', 'MAP (kPa)', 'IAT (K)', 'Fuel (mL/s)'],
    //   for (final p in fuelPoints)
    //     [p.x, rpm.toStringAsFixed(0), mapKpa, iatK, p.y.toStringAsFixed(3)]
    // ];
    final data = [
      ['Time (s)', 'RPM', 'MAP (kPa)', 'IAT (K)', 'Fuel (mL/s)'],
      ..._samples,
    ];

    await file.writeAsString(const ListToCsvConverter().convert(data));
    debugPrint("this is data $data");
    if (file.isAbsolute) {
      debugPrint("This is path ${file.path} isAbsolute ");
    }
    else{
      debugPrint("This is path ${file.path} is not Absolute");
    }
    if (file.existsSync()){
      debugPrint("This is path ${file.path} is exists");
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Trip saved: ${file.path}')));
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    scanSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fuel Trip Tracker')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(connected ? "Connected to OBD" : "Not connected",
                style: TextStyle(
                    color: connected ? Colors.green : Colors.red,
                    fontWeight: FontWeight.bold)),
            Text(_obdData),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                        labelText: "Volumetric Efficiency (%)"),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => volEff = double.tryParse(v) ?? 85,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                        labelText: "Engine Displacement (L)"),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => engDisp = double.tryParse(v) ?? 2.0,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: LineChart(LineChartData(
                lineBarsData: [
                  LineChartBarData(
                    spots: fuelPoints,
                    isCurved: true,
                    color: Colors.teal,
                    barWidth: 3,
                    belowBarData: BarAreaData(show: false),
                  )
                ],
                titlesData: FlTitlesData(show: true),
                gridData: FlGridData(show: true),
              )),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                ElevatedButton(
                  onPressed: connected ? stopTrip : startScan,
                  child: Text(connected ? "Stop Trip" : "Start Trip"),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('RPM: ${rpm.toStringAsFixed(0)}'),
                Text('MAP: ${mapKpa.toStringAsFixed(0)} kPa'),
                Text('IAT: ${iatK > 0 ? (iatK - 273.15).toStringAsFixed(0) : '--'} °C'),
                Text('Fuel: ${fuel.toStringAsFixed(2)} mL/s'),
              ],
            ),
            const SizedBox(height: 10),

          ],
        ),
      ),
    );
  }
}
