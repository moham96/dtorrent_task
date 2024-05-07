import 'dart:async';
import 'dart:io';

import 'dart:typed_data';

import 'package:dtorrent_common/dtorrent_common.dart';
import 'package:dtorrent_task/src/lsd/lsd_events.dart';
import 'package:events_emitter2/events_emitter2.dart';
import 'package:logging/logging.dart';

var _log = Logger('lsd');

// const LSD_HOST = '239.192.152.143';
// const LSD_PORT = 6771;

class LSD with EventsEmittable<LSDEvent> {
  static final String LSD_HOST_STRING = '239.192.152.143:6771\r\n';

  static final InternetAddress LSD_HOST =
      InternetAddress.fromRawAddress(Uint8List.fromList([239, 192, 152, 143]));
  static final LSD_PORT = 6771;

  static final String ANNOUNCE_FIRST_LINE = 'BT-SEARCH * HTTP/1.1\r\n';

  bool _closed = false;

  bool get isClosed => _closed;

  RawDatagramSocket? _socket;

  final String _infoHashHex;

  int? port;

  final String _peerId;

  LSD(this._infoHashHex, this._peerId);

  Timer? _timer;

  Future<void> start() async {
    if (port == null) {
      throw Exception('lsd port is not set');
    }
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
      _log.info('lsd done');
    }, onError: (e) {
      _log.warning('lsd error', e);
    });
    await _announce();
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
        var portStr = element.substring(index);
        port = int.tryParse(portStr);
      }
      if (element.startsWith('Infohash:')) {
        infoHash = element.substring(9);
      }
    }

    if (port != null && infoHash != null) {
      if (port >= 0 && port <= 63354 && infoHash.length == 40) {
        _fireLSDPeerEvent(source, port, infoHash);
      }
    }
  }

  Future<void> _announce() async {
    _timer?.cancel();
    var message = _createMessage();
    await _sendMessage(message);
    _timer = Timer(Duration(seconds: 5 * 60), () => _announce());
  }

  Future<dynamic>? _sendMessage(String message, [Completer? completer]) {
    if (_socket == null) return null;
    completer ??= Completer();
    var success = _socket?.send(message.codeUnits, LSD_HOST, LSD_PORT);
    if (success != null && !(success > 0)) {
      Timer.run(() => _sendMessage(message, completer));
    } else {
      completer.complete();
    }
    return completer.future;
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
  String _createMessage() {
    return '${ANNOUNCE_FIRST_LINE}Host: ${LSD_HOST_STRING}Port: $port\r\nInfohash: ${_infoHashHex}\r\ncookie: dt-client${_peerId}\r\n\r\n\r\n';
  }

  void close() {
    if (isClosed) return;
    events.dispose();
    _closed = true;
    _socket?.close();
    _timer?.cancel();
  }
}
