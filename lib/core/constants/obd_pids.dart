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
    "PID": "01 0F",
    "length": 1,
    "title": "IAT",
    "unit": "degC",
    "description": "<int>, [0] - 40",
    "status": true
  }
]''';
