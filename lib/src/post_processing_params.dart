import 'package:tt_bindings/src/bindings.dart';

class PostProcessingParams {
  int integrationTimePs;
  GatingRange gatingRange;

  PostProcessingParams({
    required double integrationTimeSeconds,
    required this.gatingRange,
  }) : integrationTimePs = (integrationTimeSeconds * 1e12).round();
}

class GatingRange {
  final int startPs, endPs;

  const GatingRange(this.startPs, this.endPs) : assert(startPs < endPs && startPs >= 0);

  bool inRange(MacroMicroNative timestamp) => timestamp.microTime >= startPs && timestamp.microTime <= endPs;
}