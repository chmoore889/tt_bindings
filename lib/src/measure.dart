import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';
import 'package:ffi/ffi.dart';

import 'package:tt_bindings/src/bindings.dart' as bindings;
import 'package:tt_bindings/src/correlator.dart';
import 'package:tt_bindings/src/measurement_params.dart';
import 'package:tt_bindings/src/post_processing_params.dart';

Isolate? _isolate;
SendPort? _sendPort;

Future<void> isolateFunction(SendPort sendPort) async {
  final ReceivePort receivePort = ReceivePort();

  Completer<(MeasurementParams, PostProcessingParams)> completer = Completer();
  bool shouldClose = false;
  PostProcessingParams postProcessingParams;
  receivePort.listen((message) {
    if(message is (MeasurementParams, PostProcessingParams)) {
      completer.complete(message);
    } else if(message is PostProcessingParams) {
      postProcessingParams = message;
      print('NewParams');
    } else if (message == null) {
      shouldClose = true;
      receivePort.close();
    }
  });
  sendPort.send(receivePort.sendPort);

  final Pointer<Void> nativeDevice = bindings.getTagger();
  if(nativeDevice == nullptr) {
    sendPort.send(StateError('Failed to get tagger'));
    return;
  }
  print('Got tagger, waiting for params');

  final Pointer<bindings.MeasurementParamsNative> nativeParams = malloc();
  final (MeasurementParams, PostProcessingParams) params = await completer.future;
  print('Got params');
  final MeasurementParams measurementParams = params.$1;
  final Pointer<Int> nativeParamsDetArray = malloc(measurementParams.detectorChannels.length);

  measurementParams.copyToNative(nativeParams.ref, nativeParamsDetArray);
  final Pointer<Void> nativeMeasurement = bindings.newMeasurement(nativeDevice, nativeParams.ref, measurementParams.saveDirectory?.path.toNativeUtf8() ?? nullptr);
  malloc.free(nativeParamsDetArray);
  malloc.free(nativeParams);
  if(nativeMeasurement == nullptr) {
    sendPort.send(StateError('Failed to create measurement'));
    return;
  }
  print('Starting new measurement');

  //bindings.startMeasurement(nativeMeasurement);

  const int correlationBinSizeNs = 1000;
  const int correlationBinSizePs = correlationBinSizeNs * 1000;
  final Correlator correlator = Correlator(
    initialDelayNum: 16,
    numDelaysPerCombineStage: 8,
    binSizeNs: correlationBinSizeNs,
    maxTauNs: 1000000,
  );
  int correlationBin = 0;
  int correlationIndex = 0;

  postProcessingParams = params.$2;
  int? lastMacroStartTime;
  final Map<int, int> tpsf = {};
  while(!shouldClose) {
    final Pointer<Pointer<bindings.MacroMicroNative>> macroMicroPointer = malloc();
    final Pointer<Size> lengthPointer = malloc();
    final int res = bindings.getData(nativeMeasurement, macroMicroPointer, lengthPointer);
    if(res != 0) {
      if(res == 1) {
        print('Sending error');
        sendPort.send(StateError('Out of memory'));
      } else if (res == 2) {
        print('Sending error');
        sendPort.send(StateError('TimeTagger error - There was either a USB error or an overflow'));
      } else {
        print('Sending error');
        sendPort.send(StateError('Unknown error code $res'));
      }
      return;
    }
    final macroMicro = macroMicroPointer.value;
    final length = lengthPointer.value;
    malloc.free(macroMicroPointer);
    malloc.free(lengthPointer);

    for (int x = 0; x < length; x++) {
      if(postProcessingParams.activeChannel != macroMicro[x].channel.abs()) {
        continue;
      }

      lastMacroStartTime ??= macroMicro[x].macroTime;
      
      //Max possible correlation index for the integration time
      final int maxCorrelationIndex = postProcessingParams.integrationTimePs ~/ correlationBinSizePs;

      //Correlator Calculations
      final bool inGateRange = postProcessingParams.gatingRange.inRange(macroMicro[x].microTime);
      if(inGateRange) {
        //If end of bin, add to correlator
        final int currentCorrelationIndex = (macroMicro[x].macroTime - lastMacroStartTime) ~/ correlationBinSizePs;
        if(currentCorrelationIndex != correlationIndex) {
          correlator.addPoint(correlationBin);

          for(int x = correlationIndex + 1; x < min(currentCorrelationIndex, maxCorrelationIndex); x++) {
            correlator.addPoint(0);
          }
          correlationIndex = currentCorrelationIndex % maxCorrelationIndex;
          correlationBin = 0;
        }

        correlationBin++;
      }

      //TPSF Calculations
      const int binSizePs = 50;
      int bin = macroMicro[x].microTime ~/ binSizePs * binSizePs;
      bin = bin % measurementParams.laserPeriod;

      //Integration Time Handler
      final int futureLastMacroStartTime = lastMacroStartTime + postProcessingParams.integrationTimePs;
      if(futureLastMacroStartTime < macroMicro[x].macroTime) {
        lastMacroStartTime = futureLastMacroStartTime;

        final Iterable<CorrelationPair> correlatorOutput;

        if(inGateRange) {
          //If the current photon is in the gate,
          //it is from the future integration cycle
          correlatorOutput = correlator.genOutput();
          for(int x = 0; x < correlationIndex; x++) {
            correlator.addPoint(0);
          }
        } else {
          //Otherwise, the last in-gate photon is the current one
          //and the remaining bins must be filled
          correlator.addPoint(correlationBin);
          for(int x = correlationIndex + 1; x < maxCorrelationIndex; x++) {
            correlator.addPoint(0);
          }
          correlationIndex = 0;
          correlationBin = 0;

          correlatorOutput = correlator.genOutput();
        }
        sendPort.send((tpsf, correlatorOutput));

        tpsf.clear();
      }

      tpsf.update(bin, (value) => value + 1, ifAbsent: () => 1);
    }
    malloc.free(macroMicro);

    await Future.delayed(const Duration(milliseconds: 35));
  }

  bindings.stopMeasurement(nativeMeasurement);
  bindings.freeMeasurement(nativeMeasurement);
  bindings.freeTagger(nativeDevice);
}

void updateProcessingParams(PostProcessingParams processingParams) {
  _sendPort?.send(processingParams);
}

Stream<(Map<int, int>, Iterable<CorrelationPair>)> startMeasurement(MeasurementParams measurementParams, PostProcessingParams processingParams) async* {
  if(_isolate != null) {
    throw StateError('Measurement already running');
  }

  final receivePort = ReceivePort();
  //Can't send sendport
  _isolate = await Isolate.spawn(isolateFunction, receivePort.sendPort);

  late final StreamController<(Map<int, int>, Iterable<CorrelationPair>)> output;
  output = StreamController<(Map<int, int>, Iterable<CorrelationPair>)>(
    onListen: () {
      receivePort.listen((message) {
        if (message is SendPort) {
          _sendPort = message;
          _sendPort!.send((measurementParams, processingParams));
        }
        else if (message is (Map<int, int>, Iterable<CorrelationPair>)) {
          output.add(message);
        } else if (message is Error) {
          print('Got error');
          output.addError(message);
        }
      });
    },
    onCancel: () async {
      //Setup mechanism to see isolate close
      final Completer<void> completer = Completer();
      final ReceivePort responsePort = ReceivePort();
      _isolate?.addOnExitListener(responsePort.sendPort);
      final responseSub = responsePort.listen((message) {
        completer.complete();
      });

      //Ask isolate to close
      _sendPort!.send(null);
      receivePort.close();

      await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _isolate?.kill();
        },
      );
      _isolate = null;

      responseSub.cancel();
    },
  );

  yield* output.stream;
}