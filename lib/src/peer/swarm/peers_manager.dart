import 'dart:async';
import 'dart:io';

import 'package:dart_ipify/dart_ipify.dart';
import 'package:dtorrent_parser/dtorrent_parser.dart';
import 'package:dtorrent_common/dtorrent_common.dart';
import 'package:dtorrent_task/src/peer/protocol/peer_events.dart';
import 'package:dtorrent_task/src/peer/swarm/peers_manager_events.dart';
import 'package:events_emitter2/events_emitter2.dart';
import 'package:logging/logging.dart';
import 'package:utp_protocol/utp_protocol.dart';

import '../protocol/peer.dart';
import '../extensions/pex.dart';
import '../extensions/holepunch.dart';

const MAX_ACTIVE_PEERS = 250;

const MAX_WRITE_BUFFER_SIZE = 20 * 1024 * 1024;

const MAX_UPLOADED_NOTIFY_SIZE = 1024 * 1024 * 10; // 10 mb

var _log = Logger('PeersManager');

///
/// TODO:
/// - The external Suggest Piece/Fast Allow requests are not handled.
class PeersManager with Holepunch, PEX, EventsEmittable<PeerEvent> {
  final List<InternetAddress> IGNORE_IPS = [InternetAddress.tryParse('0.0.0.0')!, InternetAddress.tryParse('127.0.0.1')!];

  bool _disposed = false;

  bool get isDisposed => _disposed;

  final Set<Peer> _activePeers = {};

  final Map<Peer, EventsListener<PeerEvent>> _peerListeners = {};

  final Set<CompactAddress> _peersAddress = {};

  final Set<InternetAddress> _incomingAddress = {};

  InternetAddress? localExternalIP;

  final Torrent _metaInfo;

  int _uploaded = 0;

  int _downloaded = 0;

  int? _startedTime;

  int? _endTime;

  int _uploadedNotifySize = 0;

  final List<List> _remoteRequest = [];

  bool _paused = false;

  Timer? _keepAliveTimer;

  final List<List<dynamic>> _pausedRequest = [];

  final Map<String, List> _pausedRemoteRequest = {};

  final String _localPeerId;

  PeersManager(this._localPeerId, this._metaInfo) {
    _init();
    // Start pex interval
    startPEX();
  }
  UTPSocketClient? _globalUTPClient;

  getGlobalUTPClient() {
    _globalUTPClient ??= UTPSocketClient();
    return _globalUTPClient!;
  }

  Future<void> _init() async {
    try {
      localExternalIP = InternetAddress.tryParse(await Ipify.ipv4());
    } catch (e) {
      // Do nothing
    }
  }

  /// Task is paused
  bool get isPaused => _paused;

  /// All peers number. Include the connecting peer.
  int get peersNumber {
    if (_peersAddress.isEmpty) return 0;
    return _peersAddress.length;
  }

  /// All connected peers number. Include seeder.
  int get connectedPeersNumber {
    if (_activePeers.isEmpty) return 0;
    return _activePeers.length;
  }

  /// All seeder number
  int get seederNumber {
    if (_activePeers.isEmpty) return 0;
    var c = 0;
    return _activePeers.fold(c, (previousValue, element) {
      if (element.isSeeder) {
        return previousValue + 1;
      }
      return previousValue;
    });
  }

  /// Since first peer connected to end time ,
  ///
  /// The end time is current, but once `dispose` this class
  /// the end time is when manager was disposed.
  int get liveTime {
    if (_startedTime == null) return 0;
    var passed = DateTime.now().millisecondsSinceEpoch - _startedTime!;
    if (_endTime != null) {
      passed = _endTime! - _startedTime!;
    }
    return passed;
  }

  /// Average download speed , b/ms
  ///
  /// This speed calculation : `total download content bytes` / [liveTime]
  double get averageDownloadSpeed {
    var live = liveTime;
    if (live == 0) return 0.0;
    return _downloaded / live;
  }

  /// Average upload speed , b/ms
  ///
  /// This speed calculation : `total upload content bytes` / [liveTime]
  double get averageUploadSpeed {
    var live = liveTime;
    if (live == 0) return 0.0;
    return _uploaded / live;
  }

  /// Current download speed , b/ms
  ///
  /// This speed calculation: sum(`active peer download speed`)
  double get currentDownloadSpeed {
    if (_activePeers.isEmpty) return 0.0;
    return _activePeers.fold(0.0, (p, element) => p + element.currentDownloadSpeed);
  }

  /// Current upload speed , b/ms
  ///
  /// This speed calculation: sum(`active peer upload speed`)
  double get uploadSpeed {
    if (_activePeers.isEmpty) return 0.0;
    return _activePeers.fold(0.0, (p, element) => p + element.averageUploadSpeed);
  }

  void _hookPeer(Peer peer) {
    if (peer.address.address == localExternalIP) return;
    if (_peerExist(peer)) return;
    _peerListeners[peer] = peer.createListener();
    // emit all peer events
    _peerListeners[peer]!.listen((event) => events.emit(event));
    _peerListeners[peer]!
      ..on<PeerDisposeEvent>(_processPeerDispose)
      ..on<PeerInterestedChanged>(_processInterestedChange)
      ..on<PeerConnected>(_peerConnected)
      ..on<PeerPieceEvent>(_processReceivePiece)
      ..on<PeerRequestEvent>(_processRemoteRequest)
      ..on<PeerSuggestPiece>(_processSuggestPiece)
      ..on<ExtendedEvent>((event) => _processExtendedMessage(peer, event.eventName, event.data));
    _registerExtended(peer);
    peer.connect();
  }

  ///  Add supported extensions here
  void _registerExtended(Peer peer) {
    _log.fine('registering extensions for peer ${peer.address}');
    peer.registerExtend('ut_pex');
    peer.registerExtend('ut_holepunch');
  }

  void _unHookPeer(Peer peer) {
    peer.events.dispose();
    _peerListeners[peer]?.dispose();
    _peerListeners.remove(peer);
  }

  bool _peerExist(Peer id) {
    return _activePeers.contains(id);
  }

  void _processExtendedMessage(Peer source, String name, dynamic data) {
    _log.fine('Processing Extended Message $name');
    if (name == 'ut_holepunch') {
      parseHolepunchMessage(data);
    }
    if (name == 'ut_pex') {
      parsePEXDatas(source, data);
    }
    if (name == 'handshake') {
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
    }
  }

  /// Add a new peer [address] , the default [type] is `PeerType.TCP`,
  /// [socket] is null.
  ///
  /// Usually [socket] is null , unless this peer was incoming connection, but
  /// this type peer was managed by [TorrentTask] , user don't need to know that.
  void addNewPeerAddress(CompactAddress? address, PeerSource source, {PeerType? type, dynamic socket}) {
    if (address == null) return;
    if (IGNORE_IPS.contains(address.address)) return;
    if (address.address == localExternalIP) return;
    if (socket != null) {
      // Indicates that it is an actively connected peer, and currently, only one IP address is allowed to connect at a time.
      if (!_incomingAddress.add(address.address)) {
        print('Discarding duplicate connection from $address');
        return;
      }
    }
    _activePeers.removeWhere((p) => p.address == address);
    _peersAddress.remove(address);
    //the code above allows reconnections

    if (_peersAddress.add(address)) {
      Peer? peer;
      if (type == null || type == PeerType.TCP) {
        peer = Peer.newTCPPeer(address, _metaInfo.infoHashBuffer, _metaInfo.pieces.length, socket, source);
      } else if (type == PeerType.UTP) {
        peer = Peer.newUTPPeer(address, _metaInfo.infoHashBuffer, _metaInfo.pieces.length, socket, source, client: getGlobalUTPClient());
      }
      if (peer != null) _hookPeer(peer);
    }
  }

  /// When read the resource content complete , invoke this method to notify
  /// this class to send it to related peer.
  ///
  /// [pieceIndex] is the index of the piece, [begin] is the byte index of the whole
  /// contents , [block] should be uint8 list, it's the sub-piece contents bytes.
  void readSubPieceComplete(int pieceIndex, int begin, List<int> block) {
    var dindex = [];
    for (var i = 0; i < _remoteRequest.length; i++) {
      var request = _remoteRequest[i];
      if (request[0] == pieceIndex && request[1] == begin) {
        dindex.add(i);
        var peer = request[2] as Peer;
        if (!peer.isDisposed) {
          if (peer.sendPiece(pieceIndex, begin, block)) {
            _uploaded += block.length;
            _uploadedNotifySize += block.length;
          }
        }
        break;
      }
    }
    if (dindex.isNotEmpty) {
      for (var i in dindex) {
        _remoteRequest.removeAt(i);
      }
      if (_uploadedNotifySize >= MAX_UPLOADED_NOTIFY_SIZE) {
        _uploadedNotifySize = 0;
        events.emit(UpdateUploaded(_uploaded));
      }
    }
  }

  void _processSuggestPiece(PeerSuggestPiece event) {}

  void _processPeerDispose(PeerDisposeEvent disposeEvent) {
    _peerListeners.remove(disposeEvent.peer);
    var reconnect = true;
    if (disposeEvent.reason is BadException) {
      reconnect = false;
    }

    _peersAddress.remove(disposeEvent.peer.address);
    _incomingAddress.remove(disposeEvent.peer.address.address);
    _activePeers.remove(disposeEvent.peer);

    _pausedRemoteRequest.remove(disposeEvent.peer.id);
    var tempIndex = [];
    for (var i = 0; i < _pausedRequest.length; i++) {
      var pr = _pausedRequest[i];
      if (pr[0] == disposeEvent.peer) {
        tempIndex.add(i);
      }
    }
    for (var index in tempIndex) {
      _pausedRequest.removeAt(index);
    }

    if (disposeEvent.reason is TCPConnectException) {
      // print('TCPConnectException');
      // addNewPeerAddress(peer.address, PeerType.UTP);
      return;
    }

    if (reconnect) {
      if (_activePeers.length < MAX_ACTIVE_PEERS && !isDisposed) {
        addNewPeerAddress(disposeEvent.peer.address, disposeEvent.peer.source, type: disposeEvent.peer.type);
      }
    } else {
      if (disposeEvent.peer.isSeeder && !isDisposed) {
        addNewPeerAddress(disposeEvent.peer.address, disposeEvent.peer.source, type: disposeEvent.peer.type);
      }
    }
  }

  void _peerConnected(PeerConnected event) {
    _startedTime ??= DateTime.now().millisecondsSinceEpoch;
    _endTime = null;
    _activePeers.add(event.peer);
    event.peer.sendHandShake(_localPeerId);
  }

  bool addPausedRequest(Peer peer, int pieceIndex) {
    if (isPaused) {
      _pausedRequest.add([peer, pieceIndex]);
      return true;
    }
    return false;
  }

  void _processReceivePiece(PeerPieceEvent event) {
    _downloaded += event.block.length;
  }

  void _processRemoteRequest(PeerRequestEvent event) {
    if (isPaused) {
      _pausedRemoteRequest[event.peer.id] ??= [];
      var pausedRequest = _pausedRemoteRequest[event.peer.id];
      pausedRequest?.add([event.peer, event.index, event.begin, event.length]);
      return;
    }
    _remoteRequest.add([event.index, event.begin, event.peer]);
  }

  void _processInterestedChange(PeerInterestedChanged event) {
    if (event.interested) {
      event.peer.sendChoke(false);
    } else {
      event.peer.sendChoke(true); // Choke it if not interested.
    }
  }

  void _sendKeepAliveToAll() {
    for (var peer in _activePeers) {
      Timer.run(() => _keepAlive(peer));
    }
  }

  void _keepAlive(Peer peer) {
    peer.sendKeepAlive();
  }

  void sendHaveToAll(int index) {
    for (var peer in _activePeers) {
      Timer.run(() => peer.sendHave(index));
    }
  }

  /// Pause the task
  ///
  /// All the incoming request message will be received but they will be stored
  /// in buffer and no response to remote.
  ///
  /// All out message/incoming connection will be processed even task is paused.
  void pause() {
    if (_paused) return;
    _paused = true;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer(Duration(seconds: 110), _sendKeepAliveToAll);
  }

  /// Resume the task
  void resume() {
    if (!_paused) return;
    _paused = false;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    for (var element in _pausedRequest) {
      var peer = element[0] as Peer;
      var index = element[1] as int;
      if (!peer.isDisposed) {
        events.emit(PieceRequest(peer, index));
      }
    }
    _pausedRequest.clear();

    _pausedRemoteRequest.forEach((key, value) {
      for (var element in value) {
        var peer = element[0] as Peer;
        var index = element[1];
        var begin = element[2];
        var length = element[3];
        if (!peer.isDisposed) {
          Timer.run(() => _processRemoteRequest(PeerRequestEvent(peer, index, begin, length)));
        }
      }
    });
    _pausedRemoteRequest.clear();
  }

  Future disposeAllSeeder([dynamic reason]) async {
    for (var peer in [..._activePeers]) {
      if (peer.isSeeder) {
        await peer.dispose(reason);
      }
    }
    return;
  }

  Future dispose() async {
    if (isDisposed) return;
    _disposed = true;
    events.dispose();
    clearHolepunch();
    clearPEX();
    _endTime = DateTime.now().millisecondsSinceEpoch;

    _remoteRequest.clear();
    _pausedRequest.clear();
    _pausedRemoteRequest.clear();
    disposePeers(Set<Peer> peers) async {
      if (peers.isNotEmpty) {
        for (var i = 0; i < peers.length; i++) {
          var peer = peers.elementAt(i);
          _unHookPeer(peer);
          await peer.dispose('Peer Manager disposed');
        }
      }
      peers.clear();
    }

    await disposePeers(_activePeers);
  }

  //TODO: test

  @override
  void addPEXPeer(dynamic source, CompactAddress address, Map options) {
    // addNewPeerAddress(address);
    // return;
    // if (options['reachable'] != null) {
    //   if (options['utp'] != null) {
    //     print('UTP/TCP reachable');
    //   }
    //   addNewPeerAddress(address);
    //   return;
    // }
    if ((options['utp'] != null || options['ut_holepunch'] != null) && options['reachable'] == null) {
      var peer = source as Peer;
      var message = getRendezvousMessage(address);
      peer.sendExtendMessage('ut_holepunch', message);
      return;
    }
    addNewPeerAddress(address, PeerSource.pex);
  }

  @override
  Iterable<Peer> get activePeers => _activePeers;

  @override
  void holePunchConnect(CompactAddress ip) {
    _log.info("holePunch connect $ip");
    addNewPeerAddress(ip, PeerSource.holepunch, type: PeerType.UTP);
  }

  int get utpPeerCount {
    return _activePeers.fold(0, (previousValue, element) {
      if (element.type == PeerType.UTP) {
        previousValue += 1;
      }
      return previousValue;
    });
  }

  double get utpDownloadSpeed {
    return _activePeers.fold(0.0, (previousValue, element) {
      if (element.type == PeerType.UTP) {
        previousValue += element.currentDownloadSpeed;
      }
      return previousValue;
    });
  }

  double get utpUploadSpeed {
    return _activePeers.fold(0.0, (previousValue, element) {
      if (element.type == PeerType.UTP) {
        previousValue += element.averageUploadSpeed;
      }
      return previousValue;
    });
  }

  @override
  void holePunchError(String err, CompactAddress ip) {
    _log.info('holepunch error - $err');
  }

  @override
  void holePunchRendezvous(CompactAddress ip) {
    // TODO: implement holePunchRendezvous
    _log.info('Received holePunch Rendezvous from $ip');
  }
}
