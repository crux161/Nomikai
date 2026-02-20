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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( UiEvent_Log value)?  log,TResult Function( UiEvent_ConnectionState value)?  connectionState,TResult Function( UiEvent_HandshakeInitiated value)?  handshakeInitiated,TResult Function( UiEvent_HandshakeComplete value)?  handshakeComplete,TResult Function( UiEvent_Progress value)?  progress,TResult Function( UiEvent_Telemetry value)?  telemetry,TResult Function( UiEvent_FrameDrop value)?  frameDrop,TResult Function( UiEvent_Fault value)?  fault,TResult Function( UiEvent_VideoFrameReceived value)?  videoFrameReceived,TResult Function( UiEvent_Error value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case UiEvent_Log() when log != null:
return log(_that);case UiEvent_ConnectionState() when connectionState != null:
return connectionState(_that);case UiEvent_HandshakeInitiated() when handshakeInitiated != null:
return handshakeInitiated(_that);case UiEvent_HandshakeComplete() when handshakeComplete != null:
return handshakeComplete(_that);case UiEvent_Progress() when progress != null:
return progress(_that);case UiEvent_Telemetry() when telemetry != null:
return telemetry(_that);case UiEvent_FrameDrop() when frameDrop != null:
return frameDrop(_that);case UiEvent_Fault() when fault != null:
return fault(_that);case UiEvent_VideoFrameReceived() when videoFrameReceived != null:
return videoFrameReceived(_that);case UiEvent_Error() when error != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( UiEvent_Log value)  log,required TResult Function( UiEvent_ConnectionState value)  connectionState,required TResult Function( UiEvent_HandshakeInitiated value)  handshakeInitiated,required TResult Function( UiEvent_HandshakeComplete value)  handshakeComplete,required TResult Function( UiEvent_Progress value)  progress,required TResult Function( UiEvent_Telemetry value)  telemetry,required TResult Function( UiEvent_FrameDrop value)  frameDrop,required TResult Function( UiEvent_Fault value)  fault,required TResult Function( UiEvent_VideoFrameReceived value)  videoFrameReceived,required TResult Function( UiEvent_Error value)  error,}){
final _that = this;
switch (_that) {
case UiEvent_Log():
return log(_that);case UiEvent_ConnectionState():
return connectionState(_that);case UiEvent_HandshakeInitiated():
return handshakeInitiated(_that);case UiEvent_HandshakeComplete():
return handshakeComplete(_that);case UiEvent_Progress():
return progress(_that);case UiEvent_Telemetry():
return telemetry(_that);case UiEvent_FrameDrop():
return frameDrop(_that);case UiEvent_Fault():
return fault(_that);case UiEvent_VideoFrameReceived():
return videoFrameReceived(_that);case UiEvent_Error():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( UiEvent_Log value)?  log,TResult? Function( UiEvent_ConnectionState value)?  connectionState,TResult? Function( UiEvent_HandshakeInitiated value)?  handshakeInitiated,TResult? Function( UiEvent_HandshakeComplete value)?  handshakeComplete,TResult? Function( UiEvent_Progress value)?  progress,TResult? Function( UiEvent_Telemetry value)?  telemetry,TResult? Function( UiEvent_FrameDrop value)?  frameDrop,TResult? Function( UiEvent_Fault value)?  fault,TResult? Function( UiEvent_VideoFrameReceived value)?  videoFrameReceived,TResult? Function( UiEvent_Error value)?  error,}){
final _that = this;
switch (_that) {
case UiEvent_Log() when log != null:
return log(_that);case UiEvent_ConnectionState() when connectionState != null:
return connectionState(_that);case UiEvent_HandshakeInitiated() when handshakeInitiated != null:
return handshakeInitiated(_that);case UiEvent_HandshakeComplete() when handshakeComplete != null:
return handshakeComplete(_that);case UiEvent_Progress() when progress != null:
return progress(_that);case UiEvent_Telemetry() when telemetry != null:
return telemetry(_that);case UiEvent_FrameDrop() when frameDrop != null:
return frameDrop(_that);case UiEvent_Fault() when fault != null:
return fault(_that);case UiEvent_VideoFrameReceived() when videoFrameReceived != null:
return videoFrameReceived(_that);case UiEvent_Error() when error != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( String msg)?  log,TResult Function( String state,  String detail)?  connectionState,TResult Function()?  handshakeInitiated,TResult Function( BigInt sessionId,  String bootstrapMode)?  handshakeComplete,TResult Function( int streamId,  BigInt frameIndex,  BigInt bytes,  BigInt frames)?  progress,TResult Function( String name,  BigInt value)?  telemetry,TResult Function( int streamId,  String reason)?  frameDrop,TResult Function( String code,  String message)?  fault,TResult Function( Uint8List data)?  videoFrameReceived,TResult Function( String msg)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case UiEvent_Log() when log != null:
return log(_that.msg);case UiEvent_ConnectionState() when connectionState != null:
return connectionState(_that.state,_that.detail);case UiEvent_HandshakeInitiated() when handshakeInitiated != null:
return handshakeInitiated();case UiEvent_HandshakeComplete() when handshakeComplete != null:
return handshakeComplete(_that.sessionId,_that.bootstrapMode);case UiEvent_Progress() when progress != null:
return progress(_that.streamId,_that.frameIndex,_that.bytes,_that.frames);case UiEvent_Telemetry() when telemetry != null:
return telemetry(_that.name,_that.value);case UiEvent_FrameDrop() when frameDrop != null:
return frameDrop(_that.streamId,_that.reason);case UiEvent_Fault() when fault != null:
return fault(_that.code,_that.message);case UiEvent_VideoFrameReceived() when videoFrameReceived != null:
return videoFrameReceived(_that.data);case UiEvent_Error() when error != null:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( String msg)  log,required TResult Function( String state,  String detail)  connectionState,required TResult Function()  handshakeInitiated,required TResult Function( BigInt sessionId,  String bootstrapMode)  handshakeComplete,required TResult Function( int streamId,  BigInt frameIndex,  BigInt bytes,  BigInt frames)  progress,required TResult Function( String name,  BigInt value)  telemetry,required TResult Function( int streamId,  String reason)  frameDrop,required TResult Function( String code,  String message)  fault,required TResult Function( Uint8List data)  videoFrameReceived,required TResult Function( String msg)  error,}) {final _that = this;
switch (_that) {
case UiEvent_Log():
return log(_that.msg);case UiEvent_ConnectionState():
return connectionState(_that.state,_that.detail);case UiEvent_HandshakeInitiated():
return handshakeInitiated();case UiEvent_HandshakeComplete():
return handshakeComplete(_that.sessionId,_that.bootstrapMode);case UiEvent_Progress():
return progress(_that.streamId,_that.frameIndex,_that.bytes,_that.frames);case UiEvent_Telemetry():
return telemetry(_that.name,_that.value);case UiEvent_FrameDrop():
return frameDrop(_that.streamId,_that.reason);case UiEvent_Fault():
return fault(_that.code,_that.message);case UiEvent_VideoFrameReceived():
return videoFrameReceived(_that.data);case UiEvent_Error():
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( String msg)?  log,TResult? Function( String state,  String detail)?  connectionState,TResult? Function()?  handshakeInitiated,TResult? Function( BigInt sessionId,  String bootstrapMode)?  handshakeComplete,TResult? Function( int streamId,  BigInt frameIndex,  BigInt bytes,  BigInt frames)?  progress,TResult? Function( String name,  BigInt value)?  telemetry,TResult? Function( int streamId,  String reason)?  frameDrop,TResult? Function( String code,  String message)?  fault,TResult? Function( Uint8List data)?  videoFrameReceived,TResult? Function( String msg)?  error,}) {final _that = this;
switch (_that) {
case UiEvent_Log() when log != null:
return log(_that.msg);case UiEvent_ConnectionState() when connectionState != null:
return connectionState(_that.state,_that.detail);case UiEvent_HandshakeInitiated() when handshakeInitiated != null:
return handshakeInitiated();case UiEvent_HandshakeComplete() when handshakeComplete != null:
return handshakeComplete(_that.sessionId,_that.bootstrapMode);case UiEvent_Progress() when progress != null:
return progress(_that.streamId,_that.frameIndex,_that.bytes,_that.frames);case UiEvent_Telemetry() when telemetry != null:
return telemetry(_that.name,_that.value);case UiEvent_FrameDrop() when frameDrop != null:
return frameDrop(_that.streamId,_that.reason);case UiEvent_Fault() when fault != null:
return fault(_that.code,_that.message);case UiEvent_VideoFrameReceived() when videoFrameReceived != null:
return videoFrameReceived(_that.data);case UiEvent_Error() when error != null:
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


class UiEvent_ConnectionState extends UiEvent {
  const UiEvent_ConnectionState({required this.state, required this.detail}): super._();
  

 final  String state;
 final  String detail;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_ConnectionStateCopyWith<UiEvent_ConnectionState> get copyWith => _$UiEvent_ConnectionStateCopyWithImpl<UiEvent_ConnectionState>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_ConnectionState&&(identical(other.state, state) || other.state == state)&&(identical(other.detail, detail) || other.detail == detail));
}


@override
int get hashCode => Object.hash(runtimeType,state,detail);

@override
String toString() {
  return 'UiEvent.connectionState(state: $state, detail: $detail)';
}


}

/// @nodoc
abstract mixin class $UiEvent_ConnectionStateCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_ConnectionStateCopyWith(UiEvent_ConnectionState value, $Res Function(UiEvent_ConnectionState) _then) = _$UiEvent_ConnectionStateCopyWithImpl;
@useResult
$Res call({
 String state, String detail
});




}
/// @nodoc
class _$UiEvent_ConnectionStateCopyWithImpl<$Res>
    implements $UiEvent_ConnectionStateCopyWith<$Res> {
  _$UiEvent_ConnectionStateCopyWithImpl(this._self, this._then);

  final UiEvent_ConnectionState _self;
  final $Res Function(UiEvent_ConnectionState) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? state = null,Object? detail = null,}) {
  return _then(UiEvent_ConnectionState(
state: null == state ? _self.state : state // ignore: cast_nullable_to_non_nullable
as String,detail: null == detail ? _self.detail : detail // ignore: cast_nullable_to_non_nullable
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
  const UiEvent_HandshakeComplete({required this.sessionId, required this.bootstrapMode}): super._();
  

 final  BigInt sessionId;
 final  String bootstrapMode;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_HandshakeCompleteCopyWith<UiEvent_HandshakeComplete> get copyWith => _$UiEvent_HandshakeCompleteCopyWithImpl<UiEvent_HandshakeComplete>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_HandshakeComplete&&(identical(other.sessionId, sessionId) || other.sessionId == sessionId)&&(identical(other.bootstrapMode, bootstrapMode) || other.bootstrapMode == bootstrapMode));
}


@override
int get hashCode => Object.hash(runtimeType,sessionId,bootstrapMode);

@override
String toString() {
  return 'UiEvent.handshakeComplete(sessionId: $sessionId, bootstrapMode: $bootstrapMode)';
}


}

/// @nodoc
abstract mixin class $UiEvent_HandshakeCompleteCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_HandshakeCompleteCopyWith(UiEvent_HandshakeComplete value, $Res Function(UiEvent_HandshakeComplete) _then) = _$UiEvent_HandshakeCompleteCopyWithImpl;
@useResult
$Res call({
 BigInt sessionId, String bootstrapMode
});




}
/// @nodoc
class _$UiEvent_HandshakeCompleteCopyWithImpl<$Res>
    implements $UiEvent_HandshakeCompleteCopyWith<$Res> {
  _$UiEvent_HandshakeCompleteCopyWithImpl(this._self, this._then);

  final UiEvent_HandshakeComplete _self;
  final $Res Function(UiEvent_HandshakeComplete) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? sessionId = null,Object? bootstrapMode = null,}) {
  return _then(UiEvent_HandshakeComplete(
sessionId: null == sessionId ? _self.sessionId : sessionId // ignore: cast_nullable_to_non_nullable
as BigInt,bootstrapMode: null == bootstrapMode ? _self.bootstrapMode : bootstrapMode // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

/// @nodoc


class UiEvent_Progress extends UiEvent {
  const UiEvent_Progress({required this.streamId, required this.frameIndex, required this.bytes, required this.frames}): super._();
  

 final  int streamId;
 final  BigInt frameIndex;
 final  BigInt bytes;
 final  BigInt frames;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_ProgressCopyWith<UiEvent_Progress> get copyWith => _$UiEvent_ProgressCopyWithImpl<UiEvent_Progress>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_Progress&&(identical(other.streamId, streamId) || other.streamId == streamId)&&(identical(other.frameIndex, frameIndex) || other.frameIndex == frameIndex)&&(identical(other.bytes, bytes) || other.bytes == bytes)&&(identical(other.frames, frames) || other.frames == frames));
}


@override
int get hashCode => Object.hash(runtimeType,streamId,frameIndex,bytes,frames);

@override
String toString() {
  return 'UiEvent.progress(streamId: $streamId, frameIndex: $frameIndex, bytes: $bytes, frames: $frames)';
}


}

/// @nodoc
abstract mixin class $UiEvent_ProgressCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_ProgressCopyWith(UiEvent_Progress value, $Res Function(UiEvent_Progress) _then) = _$UiEvent_ProgressCopyWithImpl;
@useResult
$Res call({
 int streamId, BigInt frameIndex, BigInt bytes, BigInt frames
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
@pragma('vm:prefer-inline') $Res call({Object? streamId = null,Object? frameIndex = null,Object? bytes = null,Object? frames = null,}) {
  return _then(UiEvent_Progress(
streamId: null == streamId ? _self.streamId : streamId // ignore: cast_nullable_to_non_nullable
as int,frameIndex: null == frameIndex ? _self.frameIndex : frameIndex // ignore: cast_nullable_to_non_nullable
as BigInt,bytes: null == bytes ? _self.bytes : bytes // ignore: cast_nullable_to_non_nullable
as BigInt,frames: null == frames ? _self.frames : frames // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class UiEvent_Telemetry extends UiEvent {
  const UiEvent_Telemetry({required this.name, required this.value}): super._();
  

 final  String name;
 final  BigInt value;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_TelemetryCopyWith<UiEvent_Telemetry> get copyWith => _$UiEvent_TelemetryCopyWithImpl<UiEvent_Telemetry>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_Telemetry&&(identical(other.name, name) || other.name == name)&&(identical(other.value, value) || other.value == value));
}


@override
int get hashCode => Object.hash(runtimeType,name,value);

@override
String toString() {
  return 'UiEvent.telemetry(name: $name, value: $value)';
}


}

/// @nodoc
abstract mixin class $UiEvent_TelemetryCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_TelemetryCopyWith(UiEvent_Telemetry value, $Res Function(UiEvent_Telemetry) _then) = _$UiEvent_TelemetryCopyWithImpl;
@useResult
$Res call({
 String name, BigInt value
});




}
/// @nodoc
class _$UiEvent_TelemetryCopyWithImpl<$Res>
    implements $UiEvent_TelemetryCopyWith<$Res> {
  _$UiEvent_TelemetryCopyWithImpl(this._self, this._then);

  final UiEvent_Telemetry _self;
  final $Res Function(UiEvent_Telemetry) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? name = null,Object? value = null,}) {
  return _then(UiEvent_Telemetry(
name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,value: null == value ? _self.value : value // ignore: cast_nullable_to_non_nullable
as BigInt,
  ));
}


}

/// @nodoc


class UiEvent_FrameDrop extends UiEvent {
  const UiEvent_FrameDrop({required this.streamId, required this.reason}): super._();
  

 final  int streamId;
 final  String reason;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_FrameDropCopyWith<UiEvent_FrameDrop> get copyWith => _$UiEvent_FrameDropCopyWithImpl<UiEvent_FrameDrop>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_FrameDrop&&(identical(other.streamId, streamId) || other.streamId == streamId)&&(identical(other.reason, reason) || other.reason == reason));
}


@override
int get hashCode => Object.hash(runtimeType,streamId,reason);

@override
String toString() {
  return 'UiEvent.frameDrop(streamId: $streamId, reason: $reason)';
}


}

/// @nodoc
abstract mixin class $UiEvent_FrameDropCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_FrameDropCopyWith(UiEvent_FrameDrop value, $Res Function(UiEvent_FrameDrop) _then) = _$UiEvent_FrameDropCopyWithImpl;
@useResult
$Res call({
 int streamId, String reason
});




}
/// @nodoc
class _$UiEvent_FrameDropCopyWithImpl<$Res>
    implements $UiEvent_FrameDropCopyWith<$Res> {
  _$UiEvent_FrameDropCopyWithImpl(this._self, this._then);

  final UiEvent_FrameDrop _self;
  final $Res Function(UiEvent_FrameDrop) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? streamId = null,Object? reason = null,}) {
  return _then(UiEvent_FrameDrop(
streamId: null == streamId ? _self.streamId : streamId // ignore: cast_nullable_to_non_nullable
as int,reason: null == reason ? _self.reason : reason // ignore: cast_nullable_to_non_nullable
as String,
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


class UiEvent_VideoFrameReceived extends UiEvent {
  const UiEvent_VideoFrameReceived({required this.data}): super._();
  

 final  Uint8List data;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_VideoFrameReceivedCopyWith<UiEvent_VideoFrameReceived> get copyWith => _$UiEvent_VideoFrameReceivedCopyWithImpl<UiEvent_VideoFrameReceived>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_VideoFrameReceived&&const DeepCollectionEquality().equals(other.data, data));
}


@override
int get hashCode => Object.hash(runtimeType,const DeepCollectionEquality().hash(data));

@override
String toString() {
  return 'UiEvent.videoFrameReceived(data: $data)';
}


}

/// @nodoc
abstract mixin class $UiEvent_VideoFrameReceivedCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_VideoFrameReceivedCopyWith(UiEvent_VideoFrameReceived value, $Res Function(UiEvent_VideoFrameReceived) _then) = _$UiEvent_VideoFrameReceivedCopyWithImpl;
@useResult
$Res call({
 Uint8List data
});




}
/// @nodoc
class _$UiEvent_VideoFrameReceivedCopyWithImpl<$Res>
    implements $UiEvent_VideoFrameReceivedCopyWith<$Res> {
  _$UiEvent_VideoFrameReceivedCopyWithImpl(this._self, this._then);

  final UiEvent_VideoFrameReceived _self;
  final $Res Function(UiEvent_VideoFrameReceived) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? data = null,}) {
  return _then(UiEvent_VideoFrameReceived(
data: null == data ? _self.data : data // ignore: cast_nullable_to_non_nullable
as Uint8List,
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
