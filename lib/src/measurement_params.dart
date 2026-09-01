import 'dart:ffi';
import 'dart:io';

import 'package:tt_bindings/src/bindings.dart';

class MeasurementParams {
  final int laserChannel;
  final int laserPeriod;
  final double laserTriggerVoltage;

  final List<int> detectorChannels;
  final double detectorTriggerVoltage;

  final int hardwareDelayPs;

  final Directory? saveDirectory;

  const MeasurementParams({
    required this.laserChannel,
    required this.laserPeriod,
    required this.laserTriggerVoltage,
    required this.detectorChannels,
    required this.detectorTriggerVoltage,
    this.hardwareDelayPs = 0,
    this.saveDirectory,
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
    native.hardwareDelayPs = hardwareDelayPs;
  }
}