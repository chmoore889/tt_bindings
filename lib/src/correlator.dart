class CorrelationPair {
  final double correlation;
  final double tau;

  const CorrelationPair({
    required this.correlation,
    required this.tau,
  });

  @override
  String toString() {
    return "Tau: ${tau.toStringAsExponential()}, Correlation: $correlation";
  }
}

class Correlator {
  final int initialDelayNum, numDelaysPerCombineStage, laterCombineStages;
  final int binSizeNs;

  final bool normalize, ignoreTau0;

  int get _totalTausUnadjusted =>
      initialDelayNum + laterCombineStages * numDelaysPerCombineStage;
  late final List<double> taus;

  //For calculating the average intensity
  int totalAccumulation = 0;
  int numAccumulated = 0;

  final _LinearCorrelator _initialDelays;
  late final List<_Combiner> _combiners1, _combiners2;
  late final List<_LinearCorrelator> _combineStages;

  Correlator({
    required int maxTauNs,
    required this.initialDelayNum,
    required this.numDelaysPerCombineStage,
    required this.binSizeNs,
    this.normalize = true,
    this.ignoreTau0 = true,
  })  : assert(initialDelayNum > 0),
        assert(maxTauNs > 0 && binSizeNs > 0),
        assert(initialDelayNum.isEven && numDelaysPerCombineStage.isEven),
        laterCombineStages = _combinersFromMaxDelay(
          maxDelay: maxTauNs ~/ binSizeNs,
          initialDelayNum: initialDelayNum,
          numDelaysPerCombineStage: numDelaysPerCombineStage,
        ),
        _initialDelays = _LinearCorrelator(initialDelayNum) {
    taus = _generateTaus(
      maxTauNs: maxTauNs,
      binSize: binSizeNs,
      initialDelayNum: initialDelayNum,
      totalTaus: _totalTausUnadjusted,
      numDelaysPerCombineStage: numDelaysPerCombineStage,
    );

    _combiners1 = List.generate(
      laterCombineStages,
      (index) => _Combiner(),
    );
    _combiners2 = List.generate(
      laterCombineStages,
      (index) => _Combiner(),
    );
    _combineStages = List.generate(
      laterCombineStages,
      (index) => _LinearCorrelator(numDelaysPerCombineStage),
    );

    //Adjust last combine stage to have appropriate number of delays
    if (_combineStages.isNotEmpty) {
      final int numLastDelays =
          numDelaysPerCombineStage - (_totalTausUnadjusted - taus.length);
      _combineStages.last = _LinearCorrelator(numLastDelays);
    }
  }

  void addPoint(int intensity) {
    //Handle intensity calculation
    totalAccumulation += intensity;
    numAccumulated++;

    //Provide data to initial delays
    var (val1Out, val2Out) = _initialDelays.addPoint(intensity, intensity);

    //Provide data to later combine stages
    assert(_combiners1.length == laterCombineStages &&
        _combiners2.length == laterCombineStages &&
        _combineStages.length == laterCombineStages);
    for (int x = 0; x < laterCombineStages; x++) {
      if (val2Out == null) {
        break;
      }
      final int? combine1Res = _combiners1[x].addPoint(val1Out);
      final int? combine2Res = _combiners2[x].addPoint(val2Out);

      //Both should be null at the same time
      assert((combine1Res == null) == (combine2Res == null));

      if (combine1Res == null || combine2Res == null) {
        break;
      }
      (val1Out, val2Out) = _combineStages[x].addPoint(combine1Res, combine2Res);
    }
  }

  Iterable<CorrelationPair> genOutput() {
    //Put data into dataOut
    final List<double> dataOut = [
      ..._initialDelays.correlations,
      for (_LinearCorrelator stage in _combineStages) ...stage.correlations
    ];

    //Scale down routine
    for (int x = 0; x < dataOut.length; x++) {
      if (x < initialDelayNum) {
        continue;
      } else {
        final int subtractedInitalStage = x - initialDelayNum;
        final int stageNum = subtractedInitalStage ~/ numDelaysPerCombineStage;
        final int numToDivide =
            1 << ((stageNum + 1) * 2); //Equivalent of 4^(stageNum + 1)
        dataOut[x] /= numToDivide;
      }
    }

    //Normalize to <I>^2
    if (normalize) {
      final double averageIntensity = totalAccumulation / numAccumulated;
      final double averageIntensitySquared =
          averageIntensity * averageIntensity;
      for (int x = 0; x < dataOut.length; x++) {
        dataOut[x] /= averageIntensitySquared;
      }
    }

    final Iterable<CorrelationPair> result = Iterable.generate(
      taus.length,
      (index) {
        return CorrelationPair(
          correlation: dataOut[index],
          tau: taus[index],
        );
      },
    );

    reset();

    return result.skip(ignoreTau0 ? 1 : 0);
  }

  void reset() {
    //Reset accumulators
    totalAccumulation = 0;
    numAccumulated = 0;

    //Reset correlators
    _initialDelays.reset();
    for (_Combiner combiner in _combiners1) {
      combiner.reset();
    }
    for (_Combiner combiner in _combiners2) {
      combiner.reset();
    }
    for (_LinearCorrelator stage in _combineStages) {
      stage.reset();
    }
  }

  /// Calculates the number of combiners needed to achieve the maximum delay.
  ///
  /// [maxDelay] is the maximum delay of the correlation in bins, not time.
  static int _combinersFromMaxDelay({
    required int maxDelay,
    required int initialDelayNum,
    required int numDelaysPerCombineStage,
  }) {
    if (maxDelay <= 0) {
      throw ArgumentError("Max delay must be greater than 0");
    } else if (maxDelay < initialDelayNum) {
      throw ArgumentError("Max delay must be greater than initial delay");
    } else if (maxDelay == initialDelayNum || numDelaysPerCombineStage == 0) {
      return 0;
    }

    int combiners = 0;
    int remainingDelay = maxDelay - initialDelayNum;

    while (remainingDelay > 0) {
      remainingDelay -= (1 << (combiners + 1)) * numDelaysPerCombineStage;
      combiners++;
    }
    return combiners;
  }

  static List<double> _generateTaus({
    required int maxTauNs,
    required int binSize,
    required int initialDelayNum,
    required int totalTaus,
    required int numDelaysPerCombineStage,
  }) {
    final List<double> taus = [];

    const double secondsPerNs = 1e-9;
    final double baseIncrement = binSize * secondsPerNs;

    //Initial delays
    for (int x = 0; x < initialDelayNum; x++) {
      taus.add(x * baseIncrement);
    }
    if (numDelaysPerCombineStage == 0) {
      return taus;
    }

    taus.add(initialDelayNum * baseIncrement);

    //Later combine stages
    double currentIncrement = baseIncrement * 2;
    for (int x = initialDelayNum + 1; x < totalTaus; x++) {
      final double newTau = taus.last + currentIncrement;
      if (newTau > maxTauNs * secondsPerNs) {
        break;
      }
      taus.add(newTau);

      if ((x - initialDelayNum) % numDelaysPerCombineStage == 0) {
        currentIncrement *= 2;
      }
    }

    return taus;
  }
}

class _LinearCorrelator {
  final int numDelays;
  final List<_CorrelatorStage> _stages;

  _LinearCorrelator(this.numDelays)
      : assert(numDelays > 0),
        _stages = List.generate(numDelays, (index) => _CorrelatorStage());

  (int, int?) addPoint(int val1, int val2) {
    var (val1Out, val2Out) = _stages[0].addPoint(val1, val2);

    for (int x = 1; x < numDelays; x++) {
      if (val2Out == null) {
        break;
      }
      (val1Out, val2Out) = _stages[x].addPoint(val1Out, val2Out);
    }
    return (val1Out, val2Out);
  }

  List<double> get correlations =>
      _stages.map((e) => e.correlation).toList(growable: false);

  void reset() {
    for (_CorrelatorStage stage in _stages) {
      stage.reset();
    }
  }
}

class _CorrelatorStage {
  int _accumulation = 0;
  int _numAccumulated = 0;
  int? _val2Store;

  (int, int?) addPoint(int val1, int val2) {
    _accumulation += val1 * val2;
    _numAccumulated++;

    final int? val2ForReturn = _val2Store;
    _val2Store = val2;

    return (val1, val2ForReturn);
  }

  double get correlation => _accumulation / _numAccumulated;

  void reset() {
    _accumulation = 0;
    _numAccumulated = 0;
    _val2Store = null;
  }
}

class _Combiner {
  int? lastPoint;

  int? addPoint(int val1) {
    if (lastPoint == null) {
      lastPoint = val1;
      return null;
    } else {
      final int toReturn = lastPoint! + val1;
      lastPoint = null;
      return toReturn;
    }
  }

  void reset() {
    lastPoint = null;
  }
}
