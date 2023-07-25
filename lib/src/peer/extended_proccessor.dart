import 'dart:async';
import 'dart:typed_data';

import 'package:bencode_dart/bencode_dart.dart';

mixin ExtendedProcessor {
  final Map<int, String> _extendedEventMap = {};
  int _id = 1;
  Map? _rawMap;
  final Map<int, String> _localExtended = <int, String>{};

  Map<String, int> get localExtened {
    var map = <String, int>{};
    _localExtended.forEach((key, value) {
      map[value] = key;
    });
    return map;
  }

  final Set<void Function(dynamic source, String eventName, dynamic data)>
      _eventHandler = {};

  bool onExtendedEvent(
      void Function(dynamic source, String eventName, dynamic data) handler) {
    return _eventHandler.add(handler);
  }

  bool offExtendedEvent(
      void Function(dynamic source, String eventName, dynamic data) handler) {
    return _eventHandler.remove(handler);
  }

  void registerExtened(String name) {
    _localExtended[_id] = name;
    _id++;
  }

  int? getExtendedEventId(String name) {
    if (_rawMap != null) {
      return _rawMap![name];
    }
    return null;
  }

  void processExtendMessage(int id, Uint8List message) {
    if (id == 0) {
      var data = decode(message);
      processExtendHandshake(data);
    } else {
      var name = _localExtended[id];
      if (name != null) {
        _fireExtendedEvent(name, message);
      }
    }
  }

  void _fireExtendedEvent(String name, dynamic data) {
    for (var element in _eventHandler) {
      Timer.run(() => element(this, name, data));
    }
  }

  void processExtendHandshake(dynamic data) {
    if (data == null || !(data as Map<String, dynamic>).containsKey('m')) {
      return;
    }
    var m = data['m'] as Map<String, int>;
    _rawMap = m;
    m.forEach((key, value) {
      if (value == 0) return;
      _extendedEventMap[value] = key;
    });
    _fireExtendedEvent('handshake', data);
  }

  void clearExtendedProcessors() {
    _extendedEventMap.clear();
    _eventHandler.clear();
    _rawMap?.clear();
    _localExtended.clear();
    _id = 1;
  }
}
