// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'simple.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$UiEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'UiEvent()';
}


}

/// @nodoc
class $UiEventCopyWith<$Res>  {
$UiEventCopyWith(UiEvent _, $Res Function(UiEvent) __);
}


/// Adds pattern-matching-related methods to [UiEvent].
extension UiEventPatterns on UiEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( UiEvent_Log value)?  log,TResult Function( UiEvent_HandshakeInitiated value)?  handshakeInitiated,TResult Function( UiEvent_HandshakeComplete value)?  handshakeComplete,TResult Function( UiEvent_FileDetected value)?  fileDetected,TResult Function( UiEvent_Progress value)?  progress,TResult Function( UiEvent_TransferComplete value)?  transferComplete,TResult Function( UiEvent_EarlyTermination value)?  earlyTermination,TResult Function( UiEvent_Fault value)?  fault,TResult Function( UiEvent_Metric value)?  metric,TResult Function( UiEvent_Error value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case UiEvent_Log() when log != null:
return log(_that);case UiEvent_HandshakeInitiated() when handshakeInitiated != null:
return handshakeInitiated(_that);case UiEvent_HandshakeComplete() when handshakeComplete != null:
return handshakeComplete(_that);case UiEvent_FileDetected() when fileDetected != null:
return fileDetected(_that);case UiEvent_Progress() when progress != null:
return progress(_that);case UiEvent_TransferComplete() when transferComplete != null:
return transferComplete(_that);case UiEvent_EarlyTermination() when earlyTermination != null:
return earlyTermination(_that);case UiEvent_Fault() when fault != null:
return fault(_that);case UiEvent_Metric() when metric != null:
return metric(_that);case UiEvent_Error() when error != null:
return error(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( UiEvent_Log value)  log,required TResult Function( UiEvent_HandshakeInitiated value)  handshakeInitiated,required TResult Function( UiEvent_HandshakeComplete value)  handshakeComplete,required TResult Function( UiEvent_FileDetected value)  fileDetected,required TResult Function( UiEvent_Progress value)  progress,required TResult Function( UiEvent_TransferComplete value)  transferComplete,required TResult Function( UiEvent_EarlyTermination value)  earlyTermination,required TResult Function( UiEvent_Fault value)  fault,required TResult Function( UiEvent_Metric value)  metric,required TResult Function( UiEvent_Error value)  error,}){
final _that = this;
switch (_that) {
case UiEvent_Log():
return log(_that);case UiEvent_HandshakeInitiated():
return handshakeInitiated(_that);case UiEvent_HandshakeComplete():
return handshakeComplete(_that);case UiEvent_FileDetected():
return fileDetected(_that);case UiEvent_Progress():
return progress(_that);case UiEvent_TransferComplete():
return transferComplete(_that);case UiEvent_EarlyTermination():
return earlyTermination(_that);case UiEvent_Fault():
return fault(_that);case UiEvent_Metric():
return metric(_that);case UiEvent_Error():
return error(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( UiEvent_Log value)?  log,TResult? Function( UiEvent_HandshakeInitiated value)?  handshakeInitiated,TResult? Function( UiEvent_HandshakeComplete value)?  handshakeComplete,TResult? Function( UiEvent_FileDetected value)?  fileDetected,TResult? Function( UiEvent_Progress value)?  progress,TResult? Function( UiEvent_TransferComplete value)?  transferComplete,TResult? Function( UiEvent_EarlyTermination value)?  earlyTermination,TResult? Function( UiEvent_Fault value)?  fault,TResult? Function( UiEvent_Metric value)?  metric,TResult? Function( UiEvent_Error value)?  error,}){
final _that = this;
switch (_that) {
case UiEvent_Log() when log != null:
return log(_that);case UiEvent_HandshakeInitiated() when handshakeInitiated != null:
return handshakeInitiated(_that);case UiEvent_HandshakeComplete() when handshakeComplete != null:
return handshakeComplete(_that);case UiEvent_FileDetected() when fileDetected != null:
return fileDetected(_that);case UiEvent_Progress() when progress != null:
return progress(_that);case UiEvent_TransferComplete() when transferComplete != null:
return transferComplete(_that);case UiEvent_EarlyTermination() when earlyTermination != null:
return earlyTermination(_that);case UiEvent_Fault() when fault != null:
return fault(_that);case UiEvent_Metric() when metric != null:
return metric(_that);case UiEvent_Error() when error != null:
return error(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String msg)?  log,TResult Function()?  handshakeInitiated,TResult Function()?  handshakeComplete,TResult Function( int streamId,  BigInt traceId,  String name,  BigInt size)?  fileDetected,TResult Function( int streamId,  BigInt traceId,  BigInt current,  BigInt total)?  progress,TResult Function( int streamId,  BigInt traceId,  String path)?  transferComplete,TResult Function( int streamId,  BigInt traceId)?  earlyTermination,TResult Function( String code,  String message)?  fault,TResult Function( String name,  BigInt value)?  metric,TResult Function( String msg)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case UiEvent_Log() when log != null:
return log(_that.msg);case UiEvent_HandshakeInitiated() when handshakeInitiated != null:
return handshakeInitiated();case UiEvent_HandshakeComplete() when handshakeComplete != null:
return handshakeComplete();case UiEvent_FileDetected() when fileDetected != null:
return fileDetected(_that.streamId,_that.traceId,_that.name,_that.size);case UiEvent_Progress() when progress != null:
return progress(_that.streamId,_that.traceId,_that.current,_that.total);case UiEvent_TransferComplete() when transferComplete != null:
return transferComplete(_that.streamId,_that.traceId,_that.path);case UiEvent_EarlyTermination() when earlyTermination != null:
return earlyTermination(_that.streamId,_that.traceId);case UiEvent_Fault() when fault != null:
return fault(_that.code,_that.message);case UiEvent_Metric() when metric != null:
return metric(_that.name,_that.value);case UiEvent_Error() when error != null:
return error(_that.msg);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String msg)  log,required TResult Function()  handshakeInitiated,required TResult Function()  handshakeComplete,required TResult Function( int streamId,  BigInt traceId,  String name,  BigInt size)  fileDetected,required TResult Function( int streamId,  BigInt traceId,  BigInt current,  BigInt total)  progress,required TResult Function( int streamId,  BigInt traceId,  String path)  transferComplete,required TResult Function( int streamId,  BigInt traceId)  earlyTermination,required TResult Function( String code,  String message)  fault,required TResult Function( String name,  BigInt value)  metric,required TResult Function( String msg)  error,}) {final _that = this;
switch (_that) {
case UiEvent_Log():
return log(_that.msg);case UiEvent_HandshakeInitiated():
return handshakeInitiated();case UiEvent_HandshakeComplete():
return handshakeComplete();case UiEvent_FileDetected():
return fileDetected(_that.streamId,_that.traceId,_that.name,_that.size);case UiEvent_Progress():
return progress(_that.streamId,_that.traceId,_that.current,_that.total);case UiEvent_TransferComplete():
return transferComplete(_that.streamId,_that.traceId,_that.path);case UiEvent_EarlyTermination():
return earlyTermination(_that.streamId,_that.traceId);case UiEvent_Fault():
return fault(_that.code,_that.message);case UiEvent_Metric():
return metric(_that.name,_that.value);case UiEvent_Error():
return error(_that.msg);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String msg)?  log,TResult? Function()?  handshakeInitiated,TResult? Function()?  handshakeComplete,TResult? Function( int streamId,  BigInt traceId,  String name,  BigInt size)?  fileDetected,TResult? Function( int streamId,  BigInt traceId,  BigInt current,  BigInt total)?  progress,TResult? Function( int streamId,  BigInt traceId,  String path)?  transferComplete,TResult? Function( int streamId,  BigInt traceId)?  earlyTermination,TResult? Function( String code,  String message)?  fault,TResult? Function( String name,  BigInt value)?  metric,TResult? Function( String msg)?  error,}) {final _that = this;
switch (_that) {
case UiEvent_Log() when log != null:
return log(_that.msg);case UiEvent_HandshakeInitiated() when handshakeInitiated != null:
return handshakeInitiated();case UiEvent_HandshakeComplete() when handshakeComplete != null:
return handshakeComplete();case UiEvent_FileDetected() when fileDetected != null:
return fileDetected(_that.streamId,_that.traceId,_that.name,_that.size);case UiEvent_Progress() when progress != null:
return progress(_that.streamId,_that.traceId,_that.current,_that.total);case UiEvent_TransferComplete() when transferComplete != null:
return transferComplete(_that.streamId,_that.traceId,_that.path);case UiEvent_EarlyTermination() when earlyTermination != null:
return earlyTermination(_that.streamId,_that.traceId);case UiEvent_Fault() when fault != null:
return fault(_that.code,_that.message);case UiEvent_Metric() when metric != null:
return metric(_that.name,_that.value);case UiEvent_Error() when error != null:
return error(_that.msg);case _:
  return null;

}
}

}

/// @nodoc


class UiEvent_Log extends UiEvent {
  const UiEvent_Log({required this.msg}): super._();
  

 final  String msg;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_LogCopyWith<UiEvent_Log> get copyWith => _$UiEvent_LogCopyWithImpl<UiEvent_Log>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_Log&&(identical(other.msg, msg) || other.msg == msg));
}


@override
int get hashCode => Object.hash(runtimeType,msg);

@override
String toString() {
  return 'UiEvent.log(msg: $msg)';
}


}

/// @nodoc
abstract mixin class $UiEvent_LogCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_LogCopyWith(UiEvent_Log value, $Res Function(UiEvent_Log) _then) = _$UiEvent_LogCopyWithImpl;
@useResult
$Res call({
 String msg
});




}
/// @nodoc
class _$UiEvent_LogCopyWithImpl<$Res>
    implements $UiEvent_LogCopyWith<$Res> {
  _$UiEvent_LogCopyWithImpl(this._self, this._then);

  final UiEvent_Log _self;
  final $Res Function(UiEvent_Log) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? msg = null,}) {
  return _then(UiEvent_Log(
msg: null == msg ? _self.msg : msg // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class UiEvent_HandshakeInitiated extends UiEvent {
  const UiEvent_HandshakeInitiated(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_HandshakeInitiated);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'UiEvent.handshakeInitiated()';
}


}




/// @nodoc


class UiEvent_HandshakeComplete extends UiEvent {
  const UiEvent_HandshakeComplete(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_HandshakeComplete);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'UiEvent.handshakeComplete()';
}


}




/// @nodoc


class UiEvent_FileDetected extends UiEvent {
  const UiEvent_FileDetected({required this.streamId, required this.traceId, required this.name, required this.size}): super._();
  

 final  int streamId;
 final  BigInt traceId;
 final  String name;
 final  BigInt size;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_FileDetectedCopyWith<UiEvent_FileDetected> get copyWith => _$UiEvent_FileDetectedCopyWithImpl<UiEvent_FileDetected>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_FileDetected&&(identical(other.streamId, streamId) || other.streamId == streamId)&&(identical(other.traceId, traceId) || other.traceId == traceId)&&(identical(other.name, name) || other.name == name)&&(identical(other.size, size) || other.size == size));
}


@override
int get hashCode => Object.hash(runtimeType,streamId,traceId,name,size);

@override
String toString() {
  return 'UiEvent.fileDetected(streamId: $streamId, traceId: $traceId, name: $name, size: $size)';
}


}

/// @nodoc
abstract mixin class $UiEvent_FileDetectedCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_FileDetectedCopyWith(UiEvent_FileDetected value, $Res Function(UiEvent_FileDetected) _then) = _$UiEvent_FileDetectedCopyWithImpl;
@useResult
$Res call({
 int streamId, BigInt traceId, String name, BigInt size
});




}
/// @nodoc
class _$UiEvent_FileDetectedCopyWithImpl<$Res>
    implements $UiEvent_FileDetectedCopyWith<$Res> {
  _$UiEvent_FileDetectedCopyWithImpl(this._self, this._then);

  final UiEvent_FileDetected _self;
  final $Res Function(UiEvent_FileDetected) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? streamId = null,Object? traceId = null,Object? name = null,Object? size = null,}) {
  return _then(UiEvent_FileDetected(
streamId: null == streamId ? _self.streamId : streamId // ignore: cast_nullable_to_non_nullable
as int,traceId: null == traceId ? _self.traceId : traceId // ignore: cast_nullable_to_non_nullable
as BigInt,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,size: null == size ? _self.size : size // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class UiEvent_Progress extends UiEvent {
  const UiEvent_Progress({required this.streamId, required this.traceId, required this.current, required this.total}): super._();
  

 final  int streamId;
 final  BigInt traceId;
 final  BigInt current;
 final  BigInt total;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_ProgressCopyWith<UiEvent_Progress> get copyWith => _$UiEvent_ProgressCopyWithImpl<UiEvent_Progress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_Progress&&(identical(other.streamId, streamId) || other.streamId == streamId)&&(identical(other.traceId, traceId) || other.traceId == traceId)&&(identical(other.current, current) || other.current == current)&&(identical(other.total, total) || other.total == total));
}


@override
int get hashCode => Object.hash(runtimeType,streamId,traceId,current,total);

@override
String toString() {
  return 'UiEvent.progress(streamId: $streamId, traceId: $traceId, current: $current, total: $total)';
}


}

/// @nodoc
abstract mixin class $UiEvent_ProgressCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_ProgressCopyWith(UiEvent_Progress value, $Res Function(UiEvent_Progress) _then) = _$UiEvent_ProgressCopyWithImpl;
@useResult
$Res call({
 int streamId, BigInt traceId, BigInt current, BigInt total
});




}
/// @nodoc
class _$UiEvent_ProgressCopyWithImpl<$Res>
    implements $UiEvent_ProgressCopyWith<$Res> {
  _$UiEvent_ProgressCopyWithImpl(this._self, this._then);

  final UiEvent_Progress _self;
  final $Res Function(UiEvent_Progress) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? streamId = null,Object? traceId = null,Object? current = null,Object? total = null,}) {
  return _then(UiEvent_Progress(
streamId: null == streamId ? _self.streamId : streamId // ignore: cast_nullable_to_non_nullable
as int,traceId: null == traceId ? _self.traceId : traceId // ignore: cast_nullable_to_non_nullable
as BigInt,current: null == current ? _self.current : current // ignore: cast_nullable_to_non_nullable
as BigInt,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class UiEvent_TransferComplete extends UiEvent {
  const UiEvent_TransferComplete({required this.streamId, required this.traceId, required this.path}): super._();
  

 final  int streamId;
 final  BigInt traceId;
 final  String path;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_TransferCompleteCopyWith<UiEvent_TransferComplete> get copyWith => _$UiEvent_TransferCompleteCopyWithImpl<UiEvent_TransferComplete>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_TransferComplete&&(identical(other.streamId, streamId) || other.streamId == streamId)&&(identical(other.traceId, traceId) || other.traceId == traceId)&&(identical(other.path, path) || other.path == path));
}


@override
int get hashCode => Object.hash(runtimeType,streamId,traceId,path);

@override
String toString() {
  return 'UiEvent.transferComplete(streamId: $streamId, traceId: $traceId, path: $path)';
}


}

/// @nodoc
abstract mixin class $UiEvent_TransferCompleteCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_TransferCompleteCopyWith(UiEvent_TransferComplete value, $Res Function(UiEvent_TransferComplete) _then) = _$UiEvent_TransferCompleteCopyWithImpl;
@useResult
$Res call({
 int streamId, BigInt traceId, String path
});




}
/// @nodoc
class _$UiEvent_TransferCompleteCopyWithImpl<$Res>
    implements $UiEvent_TransferCompleteCopyWith<$Res> {
  _$UiEvent_TransferCompleteCopyWithImpl(this._self, this._then);

  final UiEvent_TransferComplete _self;
  final $Res Function(UiEvent_TransferComplete) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? streamId = null,Object? traceId = null,Object? path = null,}) {
  return _then(UiEvent_TransferComplete(
streamId: null == streamId ? _self.streamId : streamId // ignore: cast_nullable_to_non_nullable
as int,traceId: null == traceId ? _self.traceId : traceId // ignore: cast_nullable_to_non_nullable
as BigInt,path: null == path ? _self.path : path // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class UiEvent_EarlyTermination extends UiEvent {
  const UiEvent_EarlyTermination({required this.streamId, required this.traceId}): super._();
  

 final  int streamId;
 final  BigInt traceId;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_EarlyTerminationCopyWith<UiEvent_EarlyTermination> get copyWith => _$UiEvent_EarlyTerminationCopyWithImpl<UiEvent_EarlyTermination>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_EarlyTermination&&(identical(other.streamId, streamId) || other.streamId == streamId)&&(identical(other.traceId, traceId) || other.traceId == traceId));
}


@override
int get hashCode => Object.hash(runtimeType,streamId,traceId);

@override
String toString() {
  return 'UiEvent.earlyTermination(streamId: $streamId, traceId: $traceId)';
}


}

/// @nodoc
abstract mixin class $UiEvent_EarlyTerminationCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_EarlyTerminationCopyWith(UiEvent_EarlyTermination value, $Res Function(UiEvent_EarlyTermination) _then) = _$UiEvent_EarlyTerminationCopyWithImpl;
@useResult
$Res call({
 int streamId, BigInt traceId
});




}
/// @nodoc
class _$UiEvent_EarlyTerminationCopyWithImpl<$Res>
    implements $UiEvent_EarlyTerminationCopyWith<$Res> {
  _$UiEvent_EarlyTerminationCopyWithImpl(this._self, this._then);

  final UiEvent_EarlyTermination _self;
  final $Res Function(UiEvent_EarlyTermination) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? streamId = null,Object? traceId = null,}) {
  return _then(UiEvent_EarlyTermination(
streamId: null == streamId ? _self.streamId : streamId // ignore: cast_nullable_to_non_nullable
as int,traceId: null == traceId ? _self.traceId : traceId // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class UiEvent_Fault extends UiEvent {
  const UiEvent_Fault({required this.code, required this.message}): super._();
  

 final  String code;
 final  String message;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_FaultCopyWith<UiEvent_Fault> get copyWith => _$UiEvent_FaultCopyWithImpl<UiEvent_Fault>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_Fault&&(identical(other.code, code) || other.code == code)&&(identical(other.message, message) || other.message == message));
}


@override
int get hashCode => Object.hash(runtimeType,code,message);

@override
String toString() {
  return 'UiEvent.fault(code: $code, message: $message)';
}


}

/// @nodoc
abstract mixin class $UiEvent_FaultCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_FaultCopyWith(UiEvent_Fault value, $Res Function(UiEvent_Fault) _then) = _$UiEvent_FaultCopyWithImpl;
@useResult
$Res call({
 String code, String message
});




}
/// @nodoc
class _$UiEvent_FaultCopyWithImpl<$Res>
    implements $UiEvent_FaultCopyWith<$Res> {
  _$UiEvent_FaultCopyWithImpl(this._self, this._then);

  final UiEvent_Fault _self;
  final $Res Function(UiEvent_Fault) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? code = null,Object? message = null,}) {
  return _then(UiEvent_Fault(
code: null == code ? _self.code : code // ignore: cast_nullable_to_non_nullable
as String,message: null == message ? _self.message : message // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class UiEvent_Metric extends UiEvent {
  const UiEvent_Metric({required this.name, required this.value}): super._();
  

 final  String name;
 final  BigInt value;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_MetricCopyWith<UiEvent_Metric> get copyWith => _$UiEvent_MetricCopyWithImpl<UiEvent_Metric>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_Metric&&(identical(other.name, name) || other.name == name)&&(identical(other.value, value) || other.value == value));
}


@override
int get hashCode => Object.hash(runtimeType,name,value);

@override
String toString() {
  return 'UiEvent.metric(name: $name, value: $value)';
}


}

/// @nodoc
abstract mixin class $UiEvent_MetricCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_MetricCopyWith(UiEvent_Metric value, $Res Function(UiEvent_Metric) _then) = _$UiEvent_MetricCopyWithImpl;
@useResult
$Res call({
 String name, BigInt value
});




}
/// @nodoc
class _$UiEvent_MetricCopyWithImpl<$Res>
    implements $UiEvent_MetricCopyWith<$Res> {
  _$UiEvent_MetricCopyWithImpl(this._self, this._then);

  final UiEvent_Metric _self;
  final $Res Function(UiEvent_Metric) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? name = null,Object? value = null,}) {
  return _then(UiEvent_Metric(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,value: null == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class UiEvent_Error extends UiEvent {
  const UiEvent_Error({required this.msg}): super._();
  

 final  String msg;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_ErrorCopyWith<UiEvent_Error> get copyWith => _$UiEvent_ErrorCopyWithImpl<UiEvent_Error>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_Error&&(identical(other.msg, msg) || other.msg == msg));
}


@override
int get hashCode => Object.hash(runtimeType,msg);

@override
String toString() {
  return 'UiEvent.error(msg: $msg)';
}


}

/// @nodoc
abstract mixin class $UiEvent_ErrorCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_ErrorCopyWith(UiEvent_Error value, $Res Function(UiEvent_Error) _then) = _$UiEvent_ErrorCopyWithImpl;
@useResult
$Res call({
 String msg
});




}
/// @nodoc
class _$UiEvent_ErrorCopyWithImpl<$Res>
    implements $UiEvent_ErrorCopyWith<$Res> {
  _$UiEvent_ErrorCopyWithImpl(this._self, this._then);

  final UiEvent_Error _self;
  final $Res Function(UiEvent_Error) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? msg = null,}) {
  return _then(UiEvent_Error(
msg: null == msg ? _self.msg : msg // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
