import 'dart:ffi';

import 'package:tt_bindings/src/bindings.dart';

class MeasurementParams {
  final int laserChannel;
  final int laserPeriod;
  final double laserTriggerVoltage;

  final List<int> detectorChannels;
  final double detectorTriggerVoltage;

  const MeasurementParams({
    required this.laserChannel,
    required this.laserPeriod,
    required this.laserTriggerVoltage,
    required this.detectorChannels,
    required this.detectorTriggerVoltage,
  });

  void copyToNative(MeasurementParamsNative native, Pointer<Int> nativeParamsDetArray) {
    native.laserChannel = laserChannel;
    native.laserPeriod = laserPeriod;
    native.laserTriggerVoltage = laserTriggerVoltage;
    native.detectorChannels = nativeParamsDetArray;
    for (int i = 0; i < detectorChannels.length; i++) {
      native.detectorChannels[i] = detectorChannels[i];
    }
    native.detectorChannelsLength = detectorChannels.length;
    native.detectorTriggerVoltage = detectorTriggerVoltage;
  }
}