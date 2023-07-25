import 'dart:async';
import 'dart:io';

import 'dart:typed_data';

import 'package:dartorrent_common/dartorrent_common.dart';

// const LSD_HOST = '239.192.152.143';
// const LSD_PORT = 6771;

class LSD {
  static final String LSD_HOST_STRING = '239.192.152.143:6771\r\n';

  static final InternetAddress LSD_HOST =
      InternetAddress.fromRawAddress(Uint8List.fromList([239, 192, 152, 143]));
  static final LSD_PORT = 6771;

  static final String ANNOUNCE_FIREST_LINE = 'BT-SEARCH * HTTP/1.1\r\n';

  bool _closed = false;

  bool get isClosed => _closed;

  RawDatagramSocket? _socket;

  final String _infoHashHex;

  int? port;

  final String _peerId;

  final Set<Function(CompactAddress address, String infoHashHex)>
      _peerHandlers = <Function(CompactAddress, String)>{};

  LSD(this._infoHashHex, this._peerId);

  Timer? _timer;

  Future<void> start() async {
    _socket ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, LSD_PORT);
    _socket?.listen((event) {
      if (event == RawSocketEvent.read) {
        var datagram = _socket?.receive();
        if (datagram != null) {
          var datas = datagram.data;
          var str = String.fromCharCodes(datas);
          _processReceive(str, datagram.address);
        }
      }
    }, onDone: () {}, onError: (e) {});
    await _announce();
  }

  bool onLSDPeer(void Function(CompactAddress address, String infoHashHex) h) {
    return _peerHandlers.add(h);
  }

  bool offLSDPeer(void Function(CompactAddress address, String infoHashHex) h) {
    return _peerHandlers.remove(h);
  }

  void _fireLSDPeerEvent(InternetAddress address, int port, String infoHash) {
    var add = CompactAddress(address, port);
    for (var element in _peerHandlers) {
      Timer.run(() => element(add, infoHash));
    }
  }

  void _processReceive(String str, InternetAddress source) {
    var strs = str.split('\r\n');
    if (strs[0] != ANNOUNCE_FIREST_LINE) return;
    int? port;
    String? infoHash;
    for (var i = 1; i < strs.length; i++) {
      var element = strs[i];
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
    return '${ANNOUNCE_FIREST_LINE}Host: ${LSD_HOST_STRING}Port: $port\r\nInfohash: ${_infoHashHex}\r\ncookie: dt-client${_peerId}\r\n\r\n\r\n';
  }

  void close() {
    if (isClosed) return;
    _closed = true;
    _socket?.close();
    _timer?.cancel();
    _peerHandlers.clear();
  }
}
