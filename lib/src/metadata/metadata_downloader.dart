import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:bencode_dart/bencode_dart.dart';
import 'package:dartorrent_common/dartorrent_common.dart';
import 'package:dht_dart/dht_dart.dart';
import 'package:torrent_tracker/torrent_tracker.dart';

import '../peer/peer.dart';
import '../peer/holepunch.dart';
import '../peer/pex.dart';
import '../utils.dart';
import 'metadata_messager.dart';

class MetadataDownloader
    with Holepunch, PEX, MetaDataMessager
    implements AnnounceOptionsProvider {
  final Set<Function(List<int> data)> _handlers = {};

  final List<InternetAddress> IGNORE_IPS = [
    InternetAddress.tryParse('0.0.0.0')!,
    InternetAddress.tryParse('127.0.0.1')!
  ];

  InternetAddress? localExtenelIP;

  int? _metaDataSize;

  int? _metaDataBlockNum;

  int? get metaDataSize => _metaDataSize;

  late String _localPeerId;

  late List<int> _infoHashBuffer;

  List<int> get infoHashBuffer => _infoHashBuffer;

  final String _infoHashString;

  final Set<Peer> _activePeers = {};

  final Set<Peer> _avalidatedPeers = {};

  final Set<CompactAddress> _peersAddress = {};

  final Set<InternetAddress> _incomingAddress = {};

  final DHT _dht = DHT();

  bool _running = false;

  final int E = 'e'.codeUnits[0];

  List<int> _infoDatas = [];

  final Queue<int> _metaDataPieces = Queue();

  final List<int> _completedPieces = [];

  final Map<String, Timer> _requestTimeout = {};

  MetadataDownloader(this._infoHashString) {
    _localPeerId = generatePeerId();
    _infoHashBuffer = hexString2Buffer(_infoHashString)!;
    assert(_infoHashBuffer.isNotEmpty && _infoHashBuffer.length == 20,
        'Info Hash String is incorrect');
  }

  void startDownload() {
    if (_running) return;
    _running = true;
    _dht.announce(String.fromCharCodes(_infoHashBuffer), 0);
    _dht.onNewPeer(_processDHTPeer);
    // ignore: unawaited_futures
    _dht.bootstrap();
  }

  Future stop() async {
    _running = false;
    await _dht.stop();
    var fs = <Future>[];
    for (var peer in _activePeers) {
      unHookPeer(peer);
      fs.add(peer.dispose());
    }
    _activePeers.clear();
    _avalidatedPeers.clear();
    _peersAddress.clear();
    _incomingAddress.clear();
    _metaDataPieces.clear();
    _completedPieces.clear();
    _requestTimeout.forEach((key, value) {
      value.cancel();
    });
    _requestTimeout.clear();
    await Stream.fromFutures(fs).toList();
  }

  bool onDownloadComplete(Function(List<int> data) h) {
    return _handlers.add(h);
  }

  bool offDownloadComplete(Function(List<int> data) h) {
    return _handlers.remove(h);
  }

  void _processDHTPeer(CompactAddress peer, String infoHash) {
    if (infoHash == _infoHashString) {
      addNewPeerAddress(peer, PeerSource.dht);
    }
  }

  /// Add a new peer [address] , the default [type] is `PeerType.TCP`,
  /// [socket] is null.
  ///
  /// Usually [socket] is null , unless this peer was incoming connection, but
  /// this type peer was managed by [TorrentTask] , user don't need to know that.
  void addNewPeerAddress(CompactAddress address, PeerSource source,
      [PeerType type = PeerType.TCP, dynamic socket]) {
    if (!_running) return;
    if (address.address == localExtenelIP) return;
    if (socket != null) {
      //  Indicates that it is an actively connecting peer, and currently, only
      //  one connection per IP address is allowed.
      if (!_incomingAddress.add(address.address)) {
        return;
      }
    }
    if (_peersAddress.add(address)) {
      Peer? peer;
      if (type == PeerType.TCP) {
        peer = Peer.newTCPPeer(
            _localPeerId, address, _infoHashBuffer, 0, socket, source);
      }
      if (type == PeerType.UTP) {
        peer = Peer.newUTPPeer(
            _localPeerId, address, _infoHashBuffer, 0, socket, source);
      }
      if (peer != null) _hookPeer(peer);
    }
  }

  void _hookPeer(Peer peer) {
    if (peer.address.address == localExtenelIP) return;
    if (_peerExsist(peer)) return;
    peer.onDispose(_processPeerDispose);
    peer.onHandShake(_processPeerHandshake);
    peer.onConnect(_peerConnected);
    peer.onExtendedEvent(_processExtendedMessage);
    _registerExtended(peer);
    peer.connect();
  }

  bool _peerExsist(Peer id) {
    return _activePeers.contains(id);
  }

  /// Add supported extensions here
  void _registerExtended(Peer peer) {
    peer.registerExtened('ut_metadata');
    peer.registerExtened('ut_pex');
    peer.registerExtened('ut_holepunch');
  }

  void unHookPeer(Peer peer) {
    peer.offDispose(_processPeerDispose);
    peer.offHandShake(_processPeerHandshake);
    peer.offConnect(_peerConnected);
    peer.offExtendedEvent(_processExtendedMessage);
  }

  void _peerConnected(dynamic source) {
    if (!_running) return;
    var peer = source as Peer;
    _activePeers.add(peer);
    peer.sendHandShake();
  }

  void _processPeerDispose(dynamic source, [dynamic reason]) {
    if (!_running) return;
    var peer = source as Peer;
    _peersAddress.remove(peer.address);
    _incomingAddress.remove(peer.address.address);
    _activePeers.remove(peer);
  }

  void _processPeerHandshake(dynamic source, String remotePeerId, data) {
    if (!_running) return;
  }

  void _processExtendedMessage(dynamic source, String name, dynamic data) {
    if (!_running) return;
    var peer = source as Peer;
    if (name == 'ut_metadata' && data is Uint8List) {
      parseMetaDataMessage(peer, data);
    }
    if (name == 'ut_holepunch') {
      parseHolepuchMessage(data, peer);
    }
    if (name == 'ut_pex') {
      parsePEXDatas(source, data);
    }
    if (name == 'handshake') {
      if (data['metadata_size'] != null && _metaDataSize == null) {
        _metaDataSize = data['metadata_size'];
        _infoDatas = List.filled(_metaDataSize!, 0);
        _metaDataBlockNum = _metaDataSize! ~/ (16 * 1024);
        if (_metaDataBlockNum! * (16 * 1024) != _metaDataSize) {
          _metaDataBlockNum = _metaDataBlockNum! + 1;
        }
        for (var i = 0; i < _metaDataBlockNum!; i++) {
          _metaDataPieces.add(i);
        }
      }

      if (localExtenelIP != null &&
          data['yourip'] != null &&
          (data['yourip'].length == 4 || data['yourip'].length == 16)) {
        InternetAddress myip;
        try {
          myip = InternetAddress.fromRawAddress(data['yourip']);
        } catch (e) {
          return;
        }
        if (IGNORE_IPS.contains(myip)) return;
        localExtenelIP = InternetAddress.fromRawAddress(data['yourip']);
      }

      var metaDataEventId = peer.getExtendedEventId('ut_metadata');
      if (metaDataEventId != null && _metaDataSize != null) {
        _avalidatedPeers.add(peer);
        _requestMetaData(peer);
      }
    }
  }

  void parseMetaDataMessage(Peer peer, Uint8List data) {
    int? index;
    var remotePeerId = peer.remotePeerId;
    try {
      for (var i = 0; i < data.length; i++) {
        if (data[i] == E && data[i + 1] == E) {
          index = i + 1;
          break;
        }
      }
      if (index != null) {
        var msg = decode(data, start: 0, end: index + 1);
        if (msg['msg_type'] == 1) {
          var piece = msg['piece'];
          if (piece != null && piece < _metaDataBlockNum) {
            var timer = _requestTimeout.remove(remotePeerId);
            timer?.cancel();
            _pieceDownloadComplete(piece, index + 1, data);
            _requestMetaData(peer);
          }
        }
        if (msg['msg_type'] == 2) {
          var piece = msg['piece'];
          if (piece != null && piece < _metaDataBlockNum) {
            _metaDataPieces.add(piece); //Return rejected piece
            var timer = _requestTimeout.remove(remotePeerId);
            timer?.cancel();
            _requestMetaData();
          }
        }
      }
    } catch (e) {
      // donothing
    }
  }

  void _pieceDownloadComplete(int piece, int start, List<int> bytes) async {
    // Prevent multiple invocations"
    if (_completedPieces.length >= _metaDataBlockNum! ||
        _completedPieces.contains(piece)) {
      return;
    }
    var started = piece * 16 * 1024;
    List.copyRange(_infoDatas, started, bytes, start);
    _completedPieces.add(piece);
    if (_completedPieces.length >= _metaDataBlockNum!) {
      // At this point, stop and emit the event
      await stop();
      for (var h in _handlers) {
        Timer.run(() {
          h(_infoDatas);
        });
      }
      return;
    }
  }

  Peer? _randomAvalidatedPeer() {
    if (_avalidatedPeers.isEmpty) return null;
    var n = _avalidatedPeers.length;
    var index = randomInt(n);
    return _avalidatedPeers.elementAt(index);
  }

  void _requestMetaData([Peer? peer]) {
    if (_metaDataPieces.isNotEmpty) {
      peer ??= _randomAvalidatedPeer();
      if (peer == null) return;
      var piece = _metaDataPieces.removeFirst();
      var msg = createRequestMessage(piece);
      var timer = Timer(Duration(seconds: 10), () {
        _metaDataPieces.add(piece);
        _requestMetaData();
      });
      _requestTimeout[peer.remotePeerId!] = timer;
      peer.sendExtendMessage('ut_metadata', msg);
    }
  }

  @override
  Iterable<Peer> get activePeers => _activePeers;

  @override
  void addPEXPeer(source, CompactAddress address, Map options) {
    if ((options['utp'] != null || options['ut_holepunch'] != null) &&
        options['reachable'] == null) {
      var peer = source as Peer;
      var message = getRendezvousMessage(address);
      peer.sendExtendMessage('ut_holepunch', message);
      return;
    }
    addNewPeerAddress(address, PeerSource.pex);
  }

  @override
  void holePunchConnect(CompactAddress targetIp) {
    addNewPeerAddress(targetIp, PeerSource.holepunch, PeerType.UTP);
  }

  @override
  void holePunchError(String err, CompactAddress targetIp) {}

  @override
  void holePunchRendezvous(CompactAddress targetIp, Peer initiatingPeer) {}

  @override
  Future<Map<String, dynamic>> getOptions(Uri uri, String infoHash) {
    var map = {
      'downloaded': 0,
      'uploaded': 0,
      'left': 16 * 1024 * 20,
      'numwant': 50,
      'compact': 1,
      'peerId': _localPeerId,
      'port': 0
    };
    return Future.value(map);
  }
}
