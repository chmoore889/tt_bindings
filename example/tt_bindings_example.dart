import 'package:tt_bindings/tt_bindings.dart';

Future<void> main() async {
  Stream<(Map<int, int>, Iterable<CorrelationPair>)> streamMeasure = startMeasurement(
    MeasurementParams(
      laserChannel: -1,
      laserPeriod: 12500,
      laserTriggerVoltage: -0.5,
      detectorChannels: [2],
      detectorTriggerVoltage: 0.9,
    ),
    PostProcessingParams(
      integrationTimeSeconds: 1,
      gatingRange: const GatingRange(7500, 7800),
      activeChannel: 2,
    ),
  );

  final streamMeasureSub = streamMeasure.listen((event) {
    //print(event);
    print('Got event');
  });

  await Future.delayed(const Duration(seconds: 35));

  await streamMeasureSub.cancel();

  print('Done');
}