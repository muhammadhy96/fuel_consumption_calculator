const String obdInitCommands = '''[
  { "command": "AT Z",   "description": "", "status": true },
  { "command": "AT E0",  "description": "", "status": true },
  { "command": "AT SP 0","description": "", "status": true },
  { "command": "AT H0",  "description": "", "status": true },
  { "command": "AT L0",  "description": "", "status": true },
  { "command": "AT S0",  "description": "", "status": true },
  { "command": "01 00",  "description": "", "status": true }
]''';

const String obdParamConfig = '''[
  {
    "PID": "01 0C",
    "length": 2,
    "title": "Engine RPM",
    "unit": "RPM",
    "description": "<double>, (( [0] * 256) + [1] ) / 4",
    "status": true
  },
  {
    "PID": "01 0B",
    "length": 1,
    "title": "MAP",
    "unit": "kPa",
    "description": "<int>, [0]",
    "status": true
  },
  {
    "PID": "01 10",
    "length": 2,
    "title": "MAF",
    "unit": "g/s",
    "description": "<double>, (( [0] * 256) + [1] ) / 100",
    "status": true
  },
  {
    "PID": "22 0101",
    "length": 2,
    "title": "MAF (extended)",
    "unit": "g/s",
    "description": "<double>, (( [0] * 256) + [1] ) / 100",
    "status": true
  },
  {
    "PID": "01 44",
    "length": 2,
    "title": "Commanded Equivalence Ratio",
    "unit": "ratio",
    "description": "<double>, (( [0] * 256) + [1] ) / 32768",
    "status": true
  },
  {
    "PID": "01 0D",
    "length": 1,
    "title": "Vehicle Speed",
    "unit": "km/h",
    "description": "<int>, [0]",
    "status": true
  },
  {
    "PID": "01 0F",
    "length": 1,
    "title": "IAT",
    "unit": "degC",
    "description": "<int>, [0] - 40",
    "status": true
  }
]''';
