import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

class BluetoothService {
  Future<void> requestEnable() async {
    await FlutterBluetoothSerial.instance.requestEnable();
  }
}
