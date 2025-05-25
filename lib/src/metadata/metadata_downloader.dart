import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:b_encode_decode/b_encode_decode.dart';
import 'package:dart_ipify/dart_ipify.dart';
import 'package:dtorrent_common/dtorrent_common.dart';
import 'package:bittorrent_dht/bittorrent_dht.dart';
import 'package:dtorrent_task/src/metadata/metadata_downloader_events.dart';
import 'package:dtorrent_task/src/peer/protocol/peer_events.dart';
import 'package:dtorrent_tracker/dtorrent_tracker.dart' hide PeerEvent;
import 'package:events_emitter2/events_emitter2.dart';
import 'package:utp_protocol/utp_protocol.dart';

import '../peer/protocol/peer.dart';
import '../peer/extensions/holepunch.dart';
import '../peer/extensions/pex.dart';
import '../utils.dart';
import 'metadata_messenger.dart';

class MetadataDownloader with Holepunch, PEX, MetaDataMessenger, EventsEmittable<MetadataDownloaderEvent> implements AnnounceOptionsProvider {
  final List<InternetAddress> IGNORE_IPS = [InternetAddress.tryParse('0.0.0.0')!, InternetAddress.tryParse('127.0.0.1')!];

  InternetAddress? localExternalIP;

  int? _metaDataSize;

  int? _metaDataBlockNum;

  int? get metaDataSize => _metaDataSize;

  num get progress => _metaDataBlockNum != null ? _completedPieces.length / _metaDataBlockNum! * 100 : 0;

  late String _localPeerId;

  late List<int> _infoHashBuffer;

  List<int> get infoHashBuffer => _infoHashBuffer;

  final String _infoHashString;

  final Set<Peer> _activePeers = {};

  final Set<Peer> _availablePeers = {};

  final Map<Peer, EventsListener<PeerEvent>> _peerListeners = {};

  final Set<CompactAddress> _peersAddress = {};

  final Set<InternetAddress> _incomingAddress = {};

  final DHT _dht = DHT();
  DHT get dht => _dht;

  bool _running = false;

  final int E = 'e'.codeUnits[0];

  List<int> _infoDatas = [];

  final Queue<int> _metaDataPieces = Queue();

  final List<int> _completedPieces = [];

  final Map<String, Timer> _requestTimeout = {};

  MetadataDownloader(this._infoHashString) {
    _localPeerId = generatePeerId();
    _infoHashBuffer = hexString2Buffer(_infoHashString)!;
    assert(_infoHashBuffer.isNotEmpty && _infoHashBuffer.length == 20, 'Info Hash String is incorrect');
    _init();
  }

  UTPSocketClient? _globalUTPClient;

  UTPSocketClient getGlobalUTPClient() {
    _globalUTPClient ??= UTPSocketClient();
    return _globalUTPClient!;
  }

  Future<void> _init() async {
    try {
      localExternalIP = InternetAddress.tryParse(await Ipify.ipv4());
    } catch (e) {
      // do nothing
    }
  }

  Future<void> startDownload() async {
    if (_running) return;
    _running = true;

    var dhtListener = _dht.createListener();
    dhtListener.on<NewPeerEvent>(_processDHTPeer);
    var port = await _dht.bootstrap();
    if (port != null) {
      _dht.announce(String.fromCharCodes(_infoHashBuffer), port);
    }
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
    _availablePeers.clear();
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

  void _processDHTPeer(NewPeerEvent event) {
    if (event.infoHash == String.fromCharCodes(_infoHashBuffer)) {
      addNewPeerAddress(event.address, PeerSource.dht);
    }
  }

  /// Add a new peer [address] , the default [type] is `PeerType.TCP`,
  /// [socket] is null.
  ///
  /// Usually [socket] is null , unless this peer was incoming connection, but
  /// this type peer was managed by [TorrentTask] , user don't need to know that.
  void addNewPeerAddress(CompactAddress address, PeerSource source, [PeerType type = PeerType.TCP, dynamic socket]) {
    if (!_running) return;
    if (address.address == localExternalIP) return;
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
        peer = Peer.newTCPPeer(address, _infoHashBuffer, 0, socket, source);
      }
      if (type == PeerType.UTP) {
        peer = Peer.newUTPPeer(address, _infoHashBuffer, 0, socket, source, client: getGlobalUTPClient());
      }
      if (peer != null) _hookPeer(peer);
    }
  }

  void _hookPeer(Peer peer) {
    if (peer.address.address == localExternalIP) return;
    if (_peerExist(peer)) return;
    _peerListeners[peer] = peer.createListener();
    _peerListeners[peer]!
      ..on<PeerDisposeEvent>((event) => _processPeerDispose(event.peer, event.reason))
      ..on<PeerHandshakeEvent>((event) => _processPeerHandshake(event.peer, event.remotePeerId, event.data))
      ..on<PeerConnected>((event) => _peerConnected(event.peer))
      ..on<ExtendedEvent>((event) => _processExtendedMessage(peer, event.eventName, event.data));
    _registerExtended(peer);
    peer.connect();
  }

  bool _peerExist(Peer id) {
    return _activePeers.contains(id);
  }

  /// Add supported extensions here
  void _registerExtended(Peer peer) {
    peer.registerExtend('ut_metadata');
    peer.registerExtend('ut_pex');
    peer.registerExtend('ut_holepunch');
  }

  void unHookPeer(Peer peer) {
    peer.events.dispose();
    _peerListeners.remove(peer);
  }

  void _peerConnected(Peer peer) {
    if (!_running) return;
    _activePeers.add(peer);
    peer.sendHandShake(_localPeerId);
  }

  void _processPeerDispose(Peer peer, [dynamic reason]) {
    _peerListeners.remove(peer);

    if (!_running) return;
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
      parseHolepunchMessage(data);
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

      if (localExternalIP != null && data['yourip'] != null && (data['yourip'].length == 4 || data['yourip'].length == 16)) {
        InternetAddress myIp;
        try {
          myIp = InternetAddress.fromRawAddress(data['yourip']);
        } catch (e) {
          return;
        }
        if (IGNORE_IPS.contains(myIp)) return;
        localExternalIP = InternetAddress.fromRawAddress(data['yourip']);
      }

      var metaDataEventId = peer.getExtendedEventId('ut_metadata');
      if (metaDataEventId != null && _metaDataSize != null) {
        _availablePeers.add(peer);
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
          // Piece message
          var piece = msg['piece'];
          if (piece != null && piece < _metaDataBlockNum) {
            var timer = _requestTimeout.remove(remotePeerId);
            timer?.cancel();
            _pieceDownloadComplete(piece, index + 1, data);
            _requestMetaData(peer);
          }
        }
        if (msg['msg_type'] == 2) {
          //  Reject piece
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
      // do nothing
    }
  }

  void _pieceDownloadComplete(int piece, int start, List<int> bytes) async {
    // Prevent multiple invocations"
    if (_completedPieces.length >= _metaDataBlockNum! || _completedPieces.contains(piece)) {
      print('Metadata piece $piece already processed or complete');
      return;
    }
    var started = piece * 16 * 1024;
    print('Piece metadata $piece downloaded, copying to _infoDatas[$started]');
    List.copyRange(_infoDatas, started, bytes, start);
    _completedPieces.add(piece);
    events.emit(MetaDataDownloadProgress(progress));
    if (_completedPieces.length >= _metaDataBlockNum!) {
      print('Metadata complete! Total pieces: ${_completedPieces.length}');
      // At this point, stop and emit the event
      await stop();
      events.emit(MetaDataDownloadComplete(_infoDatas));
      return;
    }
  }

  Peer? _randomAvailablePeer() {
    if (_availablePeers.isEmpty) return null;
    var n = _availablePeers.length;
    var index = randomInt(n);
    return _availablePeers.elementAt(index);
  }

  void _requestMetaData([Peer? peer]) {
    if (_metaDataPieces.isNotEmpty) {
      peer ??= _randomAvailablePeer();
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
    if ((options['utp'] != null || options['ut_holepunch'] != null) && options['reachable'] == null) {
      var peer = source;
      var message = getRendezvousMessage(address);
      peer.sendExtendMessage('ut_holepunch', message);
      return;
    }
    addNewPeerAddress(address, PeerSource.pex);
  }

  @override
  void holePunchConnect(CompactAddress ip) {
    addNewPeerAddress(ip, PeerSource.holepunch, PeerType.UTP);
  }

  @override
  void holePunchError(String err, CompactAddress ip) {}

  @override
  void holePunchRendezvous(CompactAddress ip) {}

  @override
  Future<Map<String, dynamic>> getOptions(Uri uri, String infoHash) {
    var map = {'downloaded': 0, 'uploaded': 0, 'left': 16 * 1024 * 20, 'numwant': 50, 'compact': 1, 'peerId': _localPeerId, 'port': 0};
    return Future.value(map);
  }
}
