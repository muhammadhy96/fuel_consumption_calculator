// OBD-II PID catalogue + bulk request configuration.
//
// All bulk requests concatenate mode-01 PIDs into a single command so the
// ELM327 issues one CAN query per poll cycle. The ECU replies with
//   41 PID1 DATA1... PID2 DATA2... PIDN DATAN...
// and we decode it ourselves via the length table in [pidByteLength].

/// Canonical hex code (no spaces, upper case) of every PID we know how to
/// decode, mapped to its data-byte length (excluding the mode/PID echo).
const Map<String, int> pidByteLength = {
  '010C': 2, // Engine RPM
  '010D': 1, // Vehicle speed
  '010B': 1, // Intake manifold absolute pressure
  '0110': 2, // MAF air-flow rate
  '0104': 1, // Calculated engine load
  '010F': 1, // Intake air temperature
  '0105': 1, // Engine coolant temperature
  '0111': 1, // Throttle position
  '0142': 2, // Control module voltage
  '015E': 2, // Engine fuel rate (if supported)
  '0144': 2, // Commanded equivalence ratio
  '012F': 1, // Fuel tank level input
  '0133': 1, // Barometric pressure
};

/// Human readable units — used by the dashboard.
const Map<String, String> pidUnits = {
  '010C': 'RPM',
  '010D': 'km/h',
  '010B': 'kPa',
  '0110': 'g/s',
  '0104': '%',
  '010F': '°C',
  '0105': '°C',
  '0111': '%',
  '0142': 'V',
  '015E': 'L/h',
  '0144': 'λ',
  '012F': '%',
  '0133': 'kPa',
};

const String obdInitCommands = '''[
  { "command": "AT Z",    "description": "reset", "status": true },
  { "command": "AT E0",   "description": "echo off", "status": true },
  { "command": "AT L0",   "description": "linefeeds off", "status": true },
  { "command": "AT S0",   "description": "spaces off", "status": true },
  { "command": "AT H0",   "description": "headers off", "status": true },
  { "command": "AT SP 0", "description": "auto protocol", "status": true },
  { "command": "AT AT2",  "description": "aggressive adaptive timing", "status": true },
  { "command": "AT ST 19","description": "100ms timeout (25 x 4ms)", "status": true },
  { "command": "AT CAF0", "description": "CAN auto format off", "status": true },
  { "command": "01 00",   "description": "probe supported pids 01-20", "status": true },
  { "command": "01 20",   "description": "probe supported pids 21-40", "status": true },
  { "command": "01 40",   "description": "probe supported pids 41-60", "status": true }
]''';

/// Fast-poll bulk command: PIDs that drive live fuel-flow calculation.
/// All six PIDs are requested in a single OBD frame, so the ELM327 returns
/// them concatenated in a single response.
const String fastBulkCommand = '01 0C 0D 0B 10 04 0F';

/// Slow-poll bulk command: secondary telemetry refreshed at 0.5Hz.
const String slowBulkCommand = '01 44 05 11 42 2F';

/// Optional "premium" command tried once on connect — when the ECU supports
/// direct fuel rate we use it instead of the MAF / MAP estimator.
const String premiumFuelRateCommand = '01 5E';

/// PID list matching [fastBulkCommand] — used to drive parsing and to know
/// which PIDs to expect each cycle.
const List<String> fastBulkPids = [
  '010C', '010D', '010B', '0110', '0104', '010F',
];

const List<String> slowBulkPids = [
  '0144', '0105', '0111', '0142', '012F',
];

/// Wraps [command] into the plugin's parameter JSON so we can send it via
/// [Obd2Plugin.getParamsFromJSON]. We only care that the plugin transmits the
/// raw OBD command — we do the decoding ourselves on the response.
String buildBulkRequestJson(String command) {
  return '[{"PID":"$command","length":0,"title":"BULK","unit":"",'
      '"description":"<int>,[0]","status":true}]';
}
