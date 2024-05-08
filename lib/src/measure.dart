import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';

import 'package:tt_bindings/src/bindings.dart' as bindings;
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
    } else if (message == null) {
      shouldClose = true;
      receivePort.close();
    }
  });
  sendPort.send(receivePort.sendPort);

  final Pointer<Void> nativeDevice = bindings.getTagger();

  final Pointer<bindings.MeasurementParamsNative> nativeParams = malloc();
  final (MeasurementParams, PostProcessingParams) params = await completer.future;
  final MeasurementParams measurementParams = params.$1;
  final Pointer<Int> nativeParamsDetArray = malloc(measurementParams.detectorChannels.length);

  measurementParams.copyToNative(nativeParams.ref, nativeParamsDetArray);
  final Pointer<Void> nativeMeasurement = bindings.newMeasurement(nativeDevice, nativeParams.ref, measurementParams.saveDirectory?.path.toNativeUtf8() ?? nullptr);
  malloc.free(nativeParamsDetArray);
  malloc.free(nativeParams);

  //bindings.startMeasurement(nativeMeasurement);

  postProcessingParams = params.$2;
  int lastMacroStartTime = 0;
  final Map<int, int> tpsf = {};
  while(!shouldClose) {
    final Pointer<Pointer<bindings.MacroMicroNative>> macroMicroPointer = malloc();
    final Pointer<Size> lengthPointer = malloc();
    final int res = bindings.getData(nativeMeasurement, macroMicroPointer, lengthPointer);
    if(res != 0) {
      throw StateError('Error getting data');
    }
    final macroMicro = macroMicroPointer.value;
    final length = lengthPointer.value;
    malloc.free(macroMicroPointer);
    malloc.free(lengthPointer);

    for (int x = 0; x < length; x++) {
      const int binSizePs = 50;
      int bin = macroMicro[x].microTime ~/ binSizePs * binSizePs;
      bin = bin % measurementParams.laserPeriod;

      if(lastMacroStartTime + postProcessingParams.integrationTimePs < macroMicro[x].macroTime) {
        lastMacroStartTime = macroMicro[x].macroTime;
        sendPort.send(tpsf);
        tpsf.clear();
      }

      tpsf.update(bin, (value) => value + 1, ifAbsent: () => 1);
    }
    malloc.free(macroMicro);

    await Future.delayed(const Duration(milliseconds: 100));
  }

  bindings.stopMeasurement(nativeMeasurement);
  bindings.freeMeasurement(nativeMeasurement);
  bindings.freeTagger(nativeDevice);
}

void updateProcessingParams(PostProcessingParams processingParams) {
  _sendPort?.send(processingParams);
}

Stream<Map<int, int>> startMeasurement(MeasurementParams measurementParams, PostProcessingParams processingParams) async* {
  if(_isolate != null) {
    throw StateError('Measurement already running');
  }

  final receivePort = ReceivePort();
  //Can't send sendport
  _isolate = await Isolate.spawn(isolateFunction, receivePort.sendPort);

  late final StreamController<Map<int, int>> tpsfs;
  tpsfs = StreamController<Map<int, int>>(
    onListen: () {
      receivePort.listen((message) {
        if (message is SendPort) {
          _sendPort = message;
          _sendPort!.send((measurementParams, processingParams));
        }
        else if (message is Map<int, int>) {
          tpsfs.add(message);
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

      await completer.future.timeout(const Duration(seconds: 5), onTimeout: () {
        _isolate?.kill();
        _isolate = null;
      });

      responseSub.cancel();
    },
  );

  yield* tpsfs.stream;
}