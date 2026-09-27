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
  '0106': 1, // Short-term fuel trim, bank 1
  '0107': 1, // Long-term fuel trim, bank 1
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
  '0106': '%',
  '0107': '%',
};

/// Canonical poll PID keys, in priority order. Keys match [pidByteLength].
const List<String> pollPidKeys = [
  '010C', '010D', '010B', '0110', '0104', '010F',
  '0105', '0144', '0106', '0107', '0111', '0142', '012F',
];

/// PIDs that must survive supported-PID filtering even if the ECU's bitmask
/// omits them — losing these would break fuel math entirely.
const Set<String> essentialPidKeys = {'010C', '010D', '010B', '0110'};

/// Max PIDs per bulk mode-01 request. ELM327 / ISO 15765-4 allows 6.
const int maxPidsPerBulkRequest = 6;

/// Optional direct fuel-rate PID — polled only when the ECU reports support.
const String fuelRatePidKey = '015E';

/// Init commands sent before protocol selection.
const List<String> obdInitPrologue = ['AT E0', 'AT L0', 'AT S0', 'AT H0'];

/// Init commands sent after protocol selection.
const List<String> obdInitEpilogue = ['AT AT2', 'AT ST 19'];

/// Supported-PID bitmask probe commands, in order.
const List<String> pidSupportProbes = ['01 00', '01 20', '01 40'];
