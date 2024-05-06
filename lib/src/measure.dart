import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';

import 'package:tt_bindings/src/bindings.dart' as bindings;
import 'package:tt_bindings/src/measurementParams.dart';

Stream<Map<int, int>> startMeasurement(MeasurementParams params) async* {
  Future<void> isolateFunction(SendPort sendPort) async {
    final ReceivePort receivePort = ReceivePort();

    Completer<MeasurementParams> completer = Completer();
    bool shouldClose = false;
    receivePort.listen((message) {
      if(message is MeasurementParams) {
        completer.complete(message);
      } else if (message == null) {
        shouldClose = true;
        receivePort.close();
      }
    });
    sendPort.send(receivePort.sendPort);

    final Pointer<Void> nativeDevice = bindings.getTagger();

    final Pointer<bindings.MeasurementParamsNative> nativeParams = malloc();
    final Pointer<Int> nativeParamsDetArray = malloc(params.detectorChannels.length);

    final MeasurementParams data = await completer.future;
    data.copyToNative(nativeParams.ref, nativeParamsDetArray);
    final Pointer<Void> nativeMeasurement = bindings.newMeasurement(nativeDevice, nativeParams.ref);
    malloc.free(nativeParamsDetArray);
    malloc.free(nativeParams);

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
        tpsf.update(macroMicro[x].microTime ~/ binSizePs, (value) => value + 1, ifAbsent: () => 1);
      }
      sendPort.send(tpsf);
      malloc.free(macroMicro);
    }

    bindings.startMeasurement(nativeMeasurement);
  }

  final receivePort = ReceivePort();
  final isolate = await Isolate.spawn(isolateFunction, receivePort.sendPort);

  late final StreamController<Map<int, int>> tpsfs;
  late final SendPort sendPort;
  tpsfs = StreamController<Map<int, int>>(
    onListen: () {
      receivePort.listen((message) {
        if (message is SendPort) {
          sendPort = message;
          sendPort.send(params);
        }
        else if (message is Map<int, int>) {
          tpsfs.add(message);
        }
      });
    },
    onCancel: () async {
      sendPort.send(null);
      receivePort.close();
      await Future.delayed(const Duration(seconds: 5));
      isolate.kill();
    },
  );

  yield* tpsfs.stream;
}