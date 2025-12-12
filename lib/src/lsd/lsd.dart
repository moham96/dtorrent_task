import 'dart:async';
import 'dart:io';

import 'dart:typed_data';

import 'package:dtorrent_common/dtorrent_common.dart';
import 'package:dtorrent_task/src/lsd/lsd_events.dart';
import 'package:events_emitter2/events_emitter2.dart';
import 'package:logging/logging.dart';

var _log = Logger('lsd');

const String LSD_HOST_STRING = '239.192.152.143:6771\r\n';

final InternetAddress LSD_HOST =
    InternetAddress.fromRawAddress(Uint8List.fromList([239, 192, 152, 143]));
const LSD_PORT = 6771;

const String ANNOUNCE_FIRST_LINE = 'BT-SEARCH * HTTP/1.1\r\n';

class LSD with EventsEmittable<LSDEvent> {
  bool _closed = false;
  bool _started = false;

  bool get isClosed => _closed;

  bool get isStarted => _started;

  RawDatagramSocket? _socket;

  final Map<String, _LSDInfo> _registeredHashes = {};

  Timer? _announceTimer;

  Future<void> start() async {
    if (_started | _closed) return;
    _socket ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, LSD_PORT);
    _socket?.listen((event) {
      if (event == RawSocketEvent.read) {
        var datagram = _socket?.receive();
        if (datagram != null) {
          var data = datagram.data;
          var str = String.fromCharCodes(data);
          _processReceive(str, datagram.address);
        }
      }
    }, onDone: () {
      _log.info('LSD socket done');
    }, onError: (e) {
      _log.warning('LSD socket error', e);
    });
    _started = true;
    _log.info('LSD manager started on port $LSD_PORT');
    _startAnnouncing();
  }

  void _fireLSDPeerEvent(InternetAddress address, int port, String infoHash) {
    var add = CompactAddress(address, port);
    events.emit(LSDNewPeer(add, infoHash));
  }

  void _processReceive(String str, InternetAddress source) {
    var strings = str.split('\r\n');
    if (strings[0] != ANNOUNCE_FIRST_LINE) return;
    int? port;
    String? infoHash;
    for (var i = 1; i < strings.length; i++) {
      var element = strings[i];
      if (element.startsWith('Port:')) {
        var index = element.indexOf('Port:');
        index += 5;
        var portStr = element.substring(index).trim();
        port = int.tryParse(portStr);
      }
      if (element.startsWith('Infohash:')) {
        infoHash = element.substring(9).trim();
      }
    }

    if (port != null && infoHash != null) {
      if (port >= 0 && port <= 63354 && infoHash.length == 40) {
        // Emit event if this info hash is registered
        if (_registeredHashes.containsKey(infoHash)) {
          _fireLSDPeerEvent(source, port, infoHash);
        }
      }
    }
  }

  Future<void> _announce() async {
    if (_socket == null) return;

    for (var info in _registeredHashes.values) {
      var port = info.port;
      var message = _createMessage(info.infoHashHex, info.peerId, port);
      await _sendMessage(message);
    }
  }

  Future<void> _sendMessage(String message) async {
    if (_socket == null) return;
    var success = _socket?.send(message.codeUnits, LSD_HOST, LSD_PORT);
    if (success == null || success <= 0) {
      // Retry on next cycle
      Timer.run(() => _sendMessage(message));
    }
  }

  /// BT-SEARCH * HTTP/1.1\r\n
  ///
  ///Host: <host>\r\n
  ///
  ///Port: <port>\r\n
  ///
  ///Infohash: <ihash>\r\n
  ///
  ///cookie: <cookie (optional)>\r\n
  ///
  ///\r\n
  ///
  ///\r\n
  String _createMessage(String infoHashHex, String peerId, int port) {
    return '${ANNOUNCE_FIRST_LINE}Host: ${LSD_HOST_STRING}Port: $port\r\nInfohash: $infoHashHex\r\ncookie: dt-client$peerId\r\n\r\n\r\n';
  }

  void _startAnnouncing() {
    _announceTimer?.cancel();
    _announce();
    _announceTimer =
        Timer.periodic(Duration(seconds: 5 * 60), (_) => _announce());
  }

  /// Register an info hash for LSD discovery
  void registerInfoHash(String infoHashHex, String peerId, int port) {
    if (_closed) {
      throw StateError('LSDManager has been disposed');
    }
    if (!_registeredHashes.containsKey(infoHashHex)) {
      _registeredHashes[infoHashHex] = _LSDInfo(infoHashHex, peerId, port);
      _log.info('Registered LSD for info hash: $infoHashHex');

      // If already started, start announcing for this hash
      if (!_closed) {
        _startAnnouncing();
      }
    }
  }

  /// Unregister an info hash
  void unregisterInfoHash(String infoHashHex) {
    if (_registeredHashes.remove(infoHashHex) != null) {
      _log.info('Unregistered LSD for info hash: $infoHashHex');
    }
  }

  /// Dispose the LSD manager
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _announceTimer?.cancel();
    _announceTimer = null;
    _registeredHashes.clear();
    _socket?.close();
    _socket = null;
    _started = false;
    events.dispose();
  }
}

class _LSDInfo {
  final String infoHashHex;
  final String peerId;
  final int port;

  _LSDInfo(this.infoHashHex, this.peerId, this.port);
}
