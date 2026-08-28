import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
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
    if (message is (MeasurementParams, PostProcessingParams)) {
      completer.complete(message);
    } else if (message is PostProcessingParams) {
      postProcessingParams = message;
      print('NewParams');
    } else if (message == null) {
      shouldClose = true;
      receivePort.close();
    }
  });
  sendPort.send(receivePort.sendPort);

  final Pointer<Void> nativeDevice = bindings.getTagger();
  if (nativeDevice == nullptr) {
    sendPort.send(StateError('Failed to get tagger'));
    return;
  }
  print('Got tagger, waiting for params');

  final Pointer<bindings.MeasurementParamsNative> nativeParams = malloc();
  final (MeasurementParams, PostProcessingParams) params =
      await completer.future;
  print('Got params');
  final MeasurementParams measurementParams = params.$1;
  final Pointer<Int> nativeParamsDetArray =
      malloc(measurementParams.detectorChannels.length);

  measurementParams.copyToNative(nativeParams.ref, nativeParamsDetArray);
  final Pointer<Void> nativeMeasurement = bindings.newMeasurement(
      nativeDevice,
      nativeParams.ref,
      measurementParams.saveDirectory?.path.toNativeUtf8() ?? nullptr);
  malloc.free(nativeParamsDetArray);
  malloc.free(nativeParams);
  if (nativeMeasurement == nullptr) {
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

  // 1. Allocate persistent memory buffer for C++ FFI
  const int maxBufferElements = 10000000;
  final Pointer<bindings.MacroMicroNative> persistentBuffer =
      malloc<bindings.MacroMicroNative>(maxBufferElements);
  final Pointer<Size> lengthPointer = malloc<Size>();

  // 2. Pre-allocate O(1) Array for TPSF
  const int binSizePs = 50;
  final int maxTpsfBins = (measurementParams.laserPeriod / binSizePs).ceil();
  final Uint32List tpsfArray = Uint32List(maxTpsfBins);

  // 3. Zero-Copy Overlapping Native Views
  final Int64List int64View =
      persistentBuffer.cast<Int64>().asTypedList((maxBufferElements * 24) ~/ 8);
  final Int16List int16View =
      persistentBuffer.cast<Int16>().asTypedList((maxBufferElements * 24) ~/ 2);

  try {
    while (!shouldClose) {
      final int res = bindings.getData(nativeMeasurement, persistentBuffer,
          maxBufferElements, lengthPointer, postProcessingParams.activeChannel);

      if (res != 0) {
        if (res == 1) {
          sendPort.send(StateError('Out of memory'));
        } else if (res == 2) {
          sendPort.send(StateError('TimeTagger error - USB error or overflow'));
        } else {
          sendPort.send(StateError('Unknown error code $res'));
        }
        return;
      }

      final length = lengthPointer.value;
      if (length == 0) {
        await Future.delayed(const Duration(milliseconds: 35));
        continue;
      }

      for (int x = 0; x < length; x++) {
        // 24-byte struct = three 8-byte chunks. macroTime is at index 1.
        final int macroTime = int64View[x * 3 + 1];

        // 24-byte struct = twelve 2-byte chunks. microTime is at index 8.
        final int microTime = int16View[x * 12 + 8];

        lastMacroStartTime ??= macroTime;

        final int maxCorrelationIndex =
            postProcessingParams.integrationTimePs ~/ correlationBinSizePs;
        final bool inGateRange =
            postProcessingParams.gatingRange.inRange(microTime);

        if (inGateRange) {
          final int currentCorrelationIndex =
              (macroTime - lastMacroStartTime) ~/ correlationBinSizePs;
          if (currentCorrelationIndex != correlationIndex) {
            correlator.addPoint(correlationBin);

            final int zerosToAdd =
                min(currentCorrelationIndex, maxCorrelationIndex) -
                    (correlationIndex + 1);
            correlator.addZeros(max(0, zerosToAdd));

            correlationIndex = currentCorrelationIndex % maxCorrelationIndex;
            correlationBin = 0;
          }
          correlationBin++;
        }

        final int binIndex = (microTime ~/ binSizePs) % maxTpsfBins;

        final int futureLastMacroStartTime =
            lastMacroStartTime + postProcessingParams.integrationTimePs;
        if (futureLastMacroStartTime < macroTime) {
          lastMacroStartTime = futureLastMacroStartTime;
          final Iterable<CorrelationPair> correlatorOutput;

          if (inGateRange) {
            correlatorOutput = correlator.genOutput();
            for (int i = 0; i < correlationIndex; i++) {
              correlator.addZeros(max(0, correlationIndex));
            }
          } else {
            correlator.addPoint(correlationBin);

            final int zerosToAdd = maxCorrelationIndex - (correlationIndex + 1);
            correlator.addZeros(max(0, zerosToAdd));

            correlationIndex = 0;
            correlationBin = 0;
            correlatorOutput = correlator.genOutput();
          }

          final Map<int, int> tpsfOutput = {};
          for (int i = 0; i < maxTpsfBins; i++) {
            if (tpsfArray[i] > 0) {
              tpsfOutput[i * binSizePs] = tpsfArray[i];
              tpsfArray[i] = 0;
            }
          }
          sendPort.send((tpsfOutput, correlatorOutput));
        }
        tpsfArray[binIndex]++;
      }

      await Future.delayed(const Duration(milliseconds: 35));
    }
  } finally {
    // Guaranteed to free memory even if an error is thrown or returned early
    malloc.free(persistentBuffer);
    malloc.free(lengthPointer);

    bindings.stopMeasurement(nativeMeasurement);
    bindings.freeMeasurement(nativeMeasurement);
    bindings.freeTagger(nativeDevice);
  }
}

void updateProcessingParams(PostProcessingParams processingParams) {
  _sendPort?.send(processingParams);
}

Stream<(Map<int, int>, Iterable<CorrelationPair>)> startMeasurement(
    MeasurementParams measurementParams,
    PostProcessingParams processingParams) async* {
  if (_isolate != null) {
    throw StateError('Measurement already running');
  }

  final receivePort = ReceivePort();
  //Can't send sendport
  _isolate = await Isolate.spawn(isolateFunction, receivePort.sendPort);

  late final StreamController<(Map<int, int>, Iterable<CorrelationPair>)>
      output;
  output = StreamController<(Map<int, int>, Iterable<CorrelationPair>)>(
    onListen: () {
      receivePort.listen((message) {
        if (message is SendPort) {
          _sendPort = message;
          _sendPort!.send((measurementParams, processingParams));
        } else if (message is (Map<int, int>, Iterable<CorrelationPair>)) {
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
