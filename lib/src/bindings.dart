import 'dart:ffi';

final class MeasurementParamsNative extends Struct {
  @Int()
  external int laserChannel;
  @Int16()
  external int laserPeriod;
  @Double()
  external double laserTriggerVoltage;


  external Pointer<Int> detectorChannels;
  @Size()
  external int detectorChannelsLength;
  @Double()
  external double detectorTriggerVoltage;
}

final class MacroMicroNative extends Struct {
  @Int8()
  external int channel;
  @LongLong()
  external int macroTime;
  @Int16()
  external int microTime;
}

//getTagger
typedef _GetTaggerFFI = Pointer<Void> Function();
typedef GetTagger = Pointer<Void> Function();

//freeTagger, freeMeasurement, startMeasurement, stopMeausrement
typedef _PointerControlFFI = Void Function(Pointer<Void>);
typedef PointerControl = void Function(Pointer<Void>);

//newMeasurement
typedef _NewMeasurementFFI = Pointer<Void> Function(Pointer<Void>, MeasurementParamsNative);
typedef NewMeasurement = Pointer<Void> Function(Pointer<Void>, MeasurementParamsNative);

//getData
typedef _GetDataFFI = Int Function(Pointer<Void>, Pointer<Pointer<MacroMicroNative>>, Pointer<Size>);
typedef GetData = int Function(Pointer<Void>, Pointer<Pointer<MacroMicroNative>>, Pointer<Size>);

final DynamicLibrary dylib = DynamicLibrary.open(r'C:\Users\Christopher\source\repos\chmoore889\TimeDomainTTUltra\x64\Release\TimeDomain_Swabian.dll');

final GetTagger getTagger = dylib.lookupFunction<_GetTaggerFFI, GetTagger>('getTagger');

final freeTaggerAddress = dylib.lookup<NativeFunction<_PointerControlFFI>>('freeTagger');
final freeTagger = freeTaggerAddress.asFunction<PointerControl>();
//final PointerControl freeTagger = dylib.lookupFunction<_PointerControlFFI, PointerControl>('freeTagger');
final freeMeasurementAddress = dylib.lookup<NativeFunction<_PointerControlFFI>>('freeMeasurement');
final freeMeasurement = freeTaggerAddress.asFunction<PointerControl>();

final PointerControl startMeasurement = dylib.lookupFunction<_PointerControlFFI, PointerControl>('startMeasurement');
final PointerControl stopMeasurement = dylib.lookupFunction<_PointerControlFFI, PointerControl>('stopMeasurement');
final NewMeasurement newMeasurement = dylib.lookupFunction<_NewMeasurementFFI, NewMeasurement>('newMeasurement');
final GetData getData = dylib.lookupFunction<_GetDataFFI, GetData>('getData');