class PostProcessingParams {
  int integrationTimePs;
  GatingRange gatingRange;
  int activeChannel;

  PostProcessingParams({
    required double integrationTimeSeconds,
    required this.gatingRange,
    required this.activeChannel,
  }) : integrationTimePs = (integrationTimeSeconds * 1e12).round();
}

class GatingRange {
  final int startPs, endPs;

  const GatingRange(this.startPs, this.endPs) : assert(startPs < endPs && startPs >= 0);

  bool inRange(int microTime) => microTime >= startPs && microTime <= endPs;
}