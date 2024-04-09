import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart_ipify/dart_ipify.dart';
import 'package:dtorrent_parser/dtorrent_parser.dart';
import 'package:dtorrent_common/dtorrent_common.dart';
import 'package:dtorrent_task/src/file/download_file_manager_events.dart';
import 'package:dtorrent_task/src/peer/peer_events.dart';
import 'package:dtorrent_task/src/peer/peers_manager_events.dart';
import 'package:dtorrent_task/src/piece/piece_manager_events.dart';
import 'package:events_emitter2/events_emitter2.dart';

import 'peer.dart';
import '../file/download_file_manager.dart';
import '../piece/piece_manager.dart';
import '../piece/piece.dart';
import '../piece/piece_provider.dart';
import '../utils.dart';
import '../peer/pex.dart';
import '../peer/holepunch.dart';

const maxActivePeers = 50;

// ignore: constant_identifier_names
const MAX_WRITE_BUFFER_SIZE = 10 * 1024 * 1024;

const maxUploadedNotifySize = 1024 * 1024 * 10; // 10 mb

///
/// TODO:
/// - The external Suggest Piece/Fast Allow requests are not handled.
class PeersManager with Holepunch, PEX, EventsEmittable<PeersManagerEvent> {
  final List<InternetAddress> ignoreIPs = [
    InternetAddress.tryParse('0.0.0.0')!,
    InternetAddress.tryParse('127.0.0.1')!
  ];

  bool _disposed = false;

  bool get isDisposed => _disposed;

  final Set<Peer> _activePeers = {};

  final Map<Peer, EventsListener<PeerEvent>> _peerListeners = {};

  final Set<CompactAddress> _peersAddress = {};

  final Set<InternetAddress> _incomingAddress = {};

  InternetAddress? localExternalIP;

  /// The maximum size of the disk write cache.
  int maxWriteBufferSize;

  final _flushIndicesBuffer = <int>{};

  final Torrent _metaInfo;

  int _uploaded = 0;

  int _downloaded = 0;

  int? _startedTime;

  int? _endTime;

  int _uploadedNotifySize = 0;

  final List<List> _remoteRequest = [];

  final DownloadFileManager _fileManager;

  final PieceProvider _pieceProvider;

  final PieceManager _pieceManager;

  bool _paused = false;

  Timer? _keepAliveTimer;

  final List<List<dynamic>> _pausedRequest = [];

  final Map<String, List> _pausedRemoteRequest = {};

  final String _localPeerId;
  EventsListener<DownloadFileManagerEvent>? fileManagerListener;
  EventsListener<PieceManagerEvent>? piecesManagerListener;

  PeersManager(this._localPeerId, this._pieceManager, this._pieceProvider,
      this._fileManager, this._metaInfo,
      [this.maxWriteBufferSize = MAX_WRITE_BUFFER_SIZE]) {
    // hook FileManager and PieceManager
    fileManagerListener = _fileManager.createListener();
    fileManagerListener
      ?..on<SubPieceWriteCompleted>(_processSubPieceWriteComplete)
      ..on<SubPieceReadCompleted>(readSubPieceComplete);
    piecesManagerListener = _pieceManager.createListener();
    piecesManagerListener?.on<PieceWriteCompleted>(_processPieceWriteComplete);
    _init();
    // Start pex interval
    startPEX();
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
    return _activePeers.fold(
        0.0, (p, element) => p + element.currentDownloadSpeed);
  }

  /// Current upload speed , b/ms
  ///
  /// This speed calculation: sum(`active peer upload speed`)
  double get uploadSpeed {
    if (_activePeers.isEmpty) return 0.0;
    return _activePeers.fold(
        0.0, (p, element) => p + element.averageUploadSpeed);
  }

  void _hookPeer(Peer peer) {
    if (peer.address.address == localExternalIP) return;
    if (_peerExist(peer)) return;
    _peerListeners[peer] = peer.createListener();
    _peerListeners[peer]!
      ..on<PeerDisposeEvent>(_processPeerDispose)
      ..on<PeerBitfieldEvent>(_processBitfieldUpdate)
      ..on<PeerHaveAll>(_processHaveAll)
      ..on<PeerHaveNone>(_processHaveNone)
      ..on<PeerHandshakeEvent>(_processPeerHandshake)
      ..on<PeerChokeChanged>(_processChokeChange)
      ..on<PeerInterestedChanged>(_processInterestedChange)
      ..on<PeerConnected>(_peerConnected)
      ..on<PeerHaveEvent>(_processHaveUpdate)
      ..on<PeerPieceEvent>(_processReceivePiece)
      ..on<PeerRequestEvent>(_processRemoteRequest)
      ..on<PeerSuggestPiece>(_processSuggestPiece)
      ..on<PeerRejectEvent>(_processRejectRequest)
      ..on<PeerAllowFast>(_processAllowFast)
      ..on<RequestTimeoutEvent>(
          (event) => _processRequestTimeout(peer, event.requests))
      ..on<ExtendedEvent>((event) =>
          _processExtendedMessage(peer, event.eventName, event.data));
    _registerExtended(peer);
    peer.connect();
  }

  ///  Add supported extensions here
  void _registerExtended(Peer peer) {
    log('registering extensions for peer ${peer.address}',
        name: runtimeType.toString());
    peer.registerExtend('ut_pex');
    peer.registerExtend('ut_holepunch');
  }

  void unHookPeer(Peer peer) {
    peer.events.dispose();
    _peerListeners[peer]?.dispose();
    _peerListeners.remove(peer);
  }

  bool _peerExist(Peer id) {
    return _activePeers.contains(id);
  }

  void _processExtendedMessage(Peer source, String name, dynamic data) {
    log('Processing Extended Message $name', name: runtimeType.toString());
    if (name == 'ut_holepunch') {
      parseHolepunchMessage(data);
    }
    if (name == 'ut_pex') {
      parsePEXDatas(source, data);
    }
    if (name == 'handshake') {
      if (localExternalIP != null &&
          data['yourip'] != null &&
          (data['yourip'].length == 4 || data['yourip'].length == 16)) {
        InternetAddress myIp;
        try {
          myIp = InternetAddress.fromRawAddress(data['yourip']);
        } catch (e) {
          return;
        }
        if (ignoreIPs.contains(myIp)) return;
        localExternalIP = InternetAddress.fromRawAddress(data['yourip']);
      }
    }
  }

  /// Add a new peer [address] , the default [type] is `PeerType.TCP`,
  /// [socket] is null.
  ///
  /// Usually [socket] is null , unless this peer was incoming connection, but
  /// this type peer was managed by [TorrentTask] , user don't need to know that.
  void addNewPeerAddress(CompactAddress? address, PeerSource source,
      {PeerType? type, dynamic socket}) {
    if (address == null) return;
    if (ignoreIPs.contains(address.address)) return;
    if (address.address == localExternalIP) return;
    if (socket != null) {
      // Indicates that it is an actively connected peer, and currently, only one IP address is allowed to connect at a time.
      if (!_incomingAddress.add(address.address)) {
        return;
      }
    }
    if (_peersAddress.add(address)) {
      Peer? peer;
      if (type == null || type == PeerType.TCP) {
        peer = Peer.newTCPPeer(_localPeerId, address, _metaInfo.infoHashBuffer,
            _metaInfo.pieces.length, socket, source);
      }
      if (type == PeerType.UTP) {
        peer = Peer.newUTPPeer(_localPeerId, address, _metaInfo.infoHashBuffer,
            _metaInfo.pieces.length, socket, source);
      }
      if (peer != null) _hookPeer(peer);
    }
  }

  void _processSubPieceWriteComplete(SubPieceWriteCompleted event) {
    _pieceManager.processSubPieceWriteComplete(
        event.pieceIndex, event.begin, event.length);
  }

  void _processPieceWriteComplete(PieceWriteCompleted event) async {
    Piece? piece = _pieceManager[event.pieceIndex];
    if (piece == null) return;
    var block = await _fileManager.readFile(piece.index, 0, piece.byteLength);
    if (block == null) return;
    var digest = sha1.convert(block);
    if (digest.toString() != piece.hashString) {
      log('Piece ${piece.index} is rejected', name: runtimeType.toString());
      for (var subPiece in {...piece.downloadedSubPieces}) {
        piece.pushSubPieceBack(subPiece);
      }
      // TODO: still need optimizing for last pieces
      for (var peer in piece.availablePeers) {
        requestPieces(peer, piece.index);
      }

      return;
    } else {
      log('Piece ${piece.index} is accepted', name: runtimeType.toString());
    }
    if (_fileManager.localHave(event.pieceIndex)) return;
    await _fileManager.updateBitfield(event.pieceIndex);
    for (var peer in _activePeers) {
      // if (!peer.remoteHave(index)) {
      peer.sendHave(event.pieceIndex);
      // }
    }
    _flushIndicesBuffer.add(event.pieceIndex);
    if (_fileManager.isAllComplete) {
      await _flushFiles(_flushIndicesBuffer);
      events.emit(AllComplete());
    } else {
      await _flushFiles(_flushIndicesBuffer);
    }
  }

  Future _flushFiles(Set<int> indices) async {
    if (indices.isEmpty) return;
    var piecesSize = _metaInfo.pieceLength;
    var buffer = indices.length * piecesSize;
    if (buffer >= maxWriteBufferSize || _fileManager.isAllComplete) {
      var temp = Set<int>.from(indices);
      indices.clear();
      await _fileManager.flushFiles(temp);
    }
    return;
  }

  /// When read the resource content complete , invoke this method to notify
  /// this class to send it to related peer.
  ///
  /// [pieceIndex] is the index of the piece, [begin] is the byte index of the whole
  /// contents , [block] should be uint8 list, it's the sub-piece contents bytes.
  void readSubPieceComplete(SubPieceReadCompleted event) {
    var dindex = [];
    for (var i = 0; i < _remoteRequest.length; i++) {
      var request = _remoteRequest[i];
      if (request[0] == event.pieceIndex && request[1] == event.begin) {
        dindex.add(i);
        var peer = request[2] as Peer;
        if (!peer.isDisposed) {
          if (peer.sendPiece(event.pieceIndex, event.begin, event.block)) {
            _uploaded += event.block.length;
            _uploadedNotifySize += event.block.length;
          }
        }
        break;
      }
    }
    if (dindex.isNotEmpty) {
      for (var i in dindex) {
        _remoteRequest.removeAt(i);
      }
      if (_uploadedNotifySize >= maxUploadedNotifySize) {
        _uploadedNotifySize = 0;
        _fileManager.updateUpload(_uploaded);
      }
    }
  }

  /// Even if the other peer has choked me, I can still download.
  void _processAllowFast(PeerAllowFast event) {
    var piece = _pieceProvider[event.index];
    if (piece != null && piece.haveAvailableSubPiece()) {
      piece.addAvailablePeer(event.peer);
      requestPieces(event.peer, event.index);
    }
  }

  void _processSuggestPiece(PeerSuggestPiece event) {}

  void _processRejectRequest(PeerRejectEvent event) {
    var piece = _pieceProvider[event.index];
    piece?.pushSubPieceLast(event.begin ~/ defaultRequestLength);
  }

  void _pushSubPiecesBack(List<List<int>> requests) {
    if (requests.isEmpty) return;
    for (var element in requests) {
      var pieceIndex = element[0];
      var begin = element[1];
      // TODO This is dangerous here. Currently, we are dividing a piece into 16 KB chunks. What if it's not the case?
      var piece = _pieceManager[pieceIndex];
      var subindex = begin ~/ defaultRequestLength;
      piece?.pushSubPiece(subindex);
    }
  }

  void _processPeerDispose(PeerDisposeEvent disposeEvent) {
    _peerListeners.remove(disposeEvent.peer);
    var reconnect = true;
    if (disposeEvent.reason is BadException) {
      reconnect = false;
    }

    _peersAddress.remove(disposeEvent.peer.address);
    _incomingAddress.remove(disposeEvent.peer.address.address);
    _activePeers.remove(disposeEvent.peer);

    var bufferRequests = disposeEvent.peer.requestBuffer;
    _pushSubPiecesBack(bufferRequests);

    var completedPieces = disposeEvent.peer.remoteCompletePieces;
    for (var index in completedPieces) {
      _pieceProvider[index]?.removeAvailablePeer(disposeEvent.peer);
    }
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
      if (_activePeers.length < maxActivePeers && !isDisposed) {
        addNewPeerAddress(
          disposeEvent.peer.address,
          disposeEvent.peer.source,
          type: disposeEvent.peer.type,
        );
      }
    } else {
      if (disposeEvent.peer.isSeeder &&
          !_fileManager.isAllComplete &&
          !isDisposed) {
        addNewPeerAddress(disposeEvent.peer.address, disposeEvent.peer.source,
            type: disposeEvent.peer.type);
      }
    }
  }

  void _peerConnected(PeerConnected event) {
    _startedTime ??= DateTime.now().millisecondsSinceEpoch;
    _endTime = null;
    _activePeers.add(event.peer);
    event.peer.sendHandShake();
  }

  void requestPieces(Peer peer, [int pieceIndex = -1]) async {
    if (isPaused) {
      _pausedRequest.add([peer, pieceIndex]);
      return;
    }
    Piece? piece;
    if (pieceIndex != -1) {
      piece = _pieceProvider[pieceIndex];
      if (piece != null && !piece.haveAvailableSubPiece()) {
        piece = _pieceManager.selectPiece(peer, peer.remoteCompletePieces,
            _pieceProvider, peer.remoteSuggestPieces);
      }
    } else {
      piece = _pieceManager.selectPiece(peer, peer.remoteCompletePieces,
          _pieceProvider, peer.remoteSuggestPieces);
    }
    if (piece == null) return;

    var subIndex = piece.popSubPiece();
    if (subIndex == null) return;
    var size = defaultRequestLength; // Block size is calculated dynamically.
    var begin = subIndex * size;
    if ((begin + size) > piece.byteLength) {
      size = piece.byteLength - begin;
    }
    if (!peer.sendRequest(piece.index, begin, size)) {
      piece.pushSubPiece(subIndex);
    } else {
      Timer.run(() => requestPieces(peer, pieceIndex));
    }
  }

  void _processReceivePiece(PeerPieceEvent event) {
    _downloaded += event.block.length;

    var piece = _pieceManager[event.index];
    var i = event.index;
    if (piece != null) {
      var blockStart = piece.offset + event.begin;
      var blockEnd = blockStart + event.block.length;
      if (blockEnd > piece.end) {
        log('Error:',
            error: 'Piece overlaps with next piece',
            name: runtimeType.toString());
        return;
      }

      // TODO: improve
      if (!piece.isCompleted) {
        Timer.run(() =>
            _fileManager.writeFile(event.index, event.begin, event.block));
        piece.subPieceDownloadComplete(event.begin);
      }
      if (piece.haveAvailableSubPiece()) i = -1;
    }
    Timer.run(() => requestPieces(event.peer, i));
  }

  void _processPeerHandshake(PeerHandshakeEvent event) {
    event.peer.sendBitfield(_fileManager.localBitfield);
  }

  void _processRemoteRequest(PeerRequestEvent event) {
    if (isPaused) {
      _pausedRemoteRequest[event.peer.id] ??= [];
      var pausedRequest = _pausedRemoteRequest[event.peer.id];
      pausedRequest?.add([event.peer, event.index, event.begin, event.length]);
      return;
    }
    _remoteRequest.add([event.index, event.begin, event.peer]);
    _fileManager.readFile(event.index, event.begin, event.length);
  }

  void _processHaveAll(PeerHaveAll event) {
    _processBitfieldUpdate(
        PeerBitfieldEvent(event.peer, event.peer.remoteBitfield));
  }

  void _processHaveNone(PeerHaveNone event) {
    _processBitfieldUpdate(PeerBitfieldEvent(event.peer, null));
  }

  void _processBitfieldUpdate(PeerBitfieldEvent bitfieldEvent) {
    if (bitfieldEvent.bitfield != null) {
      if (bitfieldEvent.peer.interestedRemote) return;
      if (_fileManager.isAllComplete && bitfieldEvent.peer.isSeeder) {
        bitfieldEvent.peer.dispose(BadException(
            "Do not connect to Seeder if the download is already completed"));
        return;
      }
      for (var i = 0; i < _fileManager.piecesNumber; i++) {
        if (bitfieldEvent.bitfield!.getBit(i)) {
          if (!bitfieldEvent.peer.interestedRemote &&
              !_fileManager.localHave(i)) {
            bitfieldEvent.peer.sendInterested(true);
            return;
          }
        }
      }
    }
    bitfieldEvent.peer.sendInterested(false);
  }

  void _processHaveUpdate(PeerHaveEvent event) {
    var flag = false;
    for (var index in event.indices) {
      if (_pieceProvider[index] == null) continue;

      if (!_fileManager.localHave(index)) {
        if (event.peer.chokeMe) {
          event.peer.sendInterested(true);
        } else {
          flag = true;
          _pieceProvider[index]?.addAvailablePeer(event.peer);
        }
      }
    }
    if (flag && event.peer.isSleeping) {
      Timer.run(() => requestPieces(event.peer));
    }
  }

  void _processChokeChange(PeerChokeChanged event) {
    // Update available peers for pieces.
    if (!event.choked) {
      var completedPieces = event.peer.remoteCompletePieces;
      for (var index in completedPieces) {
        _pieceProvider[index]?.addAvailablePeer(event.peer);
      }
      // Here, start notifying requests.
      Timer.run(() => requestPieces(event.peer));
    } else {
      var completedPieces = event.peer.remoteCompletePieces;
      for (var index in completedPieces) {
        _pieceProvider[index]?.removeAvailablePeer(event.peer);
      }
    }
  }

  void _processInterestedChange(PeerInterestedChanged event) {
    if (event.interested) {
      event.peer.sendChoke(false);
    } else {
      event.peer.sendChoke(true); // Choke it if not interested.
    }
  }

  void _processRequestTimeout(Peer peer, List<List<int>> requests) {
    var flag = false;
    for (var element in requests) {
      if (element[4] >= 3) {
        flag = true;
        Timer.run(() => peer.requestCancel(element[0], element[1], element[2]));
        var index = element[0];
        var begin = element[1];
        var subindex = begin ~/ defaultRequestLength;
        var piece = _pieceManager[index];
        piece?.pushSubPiece(subindex);
      }
    }
    // Wake up other possibly idle peers.
    if (flag) {
      for (var p in _activePeers) {
        if (p != peer && p.isSleeping) {
          Timer.run(() => requestPieces(p));
        }
      }
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
      var index = element[1];
      if (!peer.isDisposed) Timer.run(() => requestPieces(peer, index));
    }
    _pausedRequest.clear();

    _pausedRemoteRequest.forEach((key, value) {
      for (var element in value) {
        var peer = element[0] as Peer;
        var index = element[1];
        var begin = element[2];
        var length = element[3];
        if (!peer.isDisposed) {
          Timer.run(() => _processRemoteRequest(
              PeerRequestEvent(peer, index, begin, length)));
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
    fileManagerListener?.dispose();
    piecesManagerListener?.dispose();
    clearHolepunch();
    clearPEX();
    _endTime = DateTime.now().millisecondsSinceEpoch;

    await _flushFiles(_flushIndicesBuffer);
    _flushIndicesBuffer.clear();
    _remoteRequest.clear();
    _pausedRequest.clear();
    _pausedRemoteRequest.clear();
    disposePeers(Set<Peer> peers) async {
      if (peers.isNotEmpty) {
        for (var i = 0; i < peers.length; i++) {
          var peer = peers.elementAt(i);
          unHookPeer(peer);
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
  Iterable<Peer> get activePeers => _activePeers;

  @override
  void holePunchConnect(CompactAddress ip) {
    log("holePunch connect $ip");
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
    log('holepunch error - $err');
  }

  @override
  void holePunchRendezvous(CompactAddress ip) {
    // TODO: implement holePunchRendezvous
    log('Received holePunch Rendezvous from $ip');
  }
}
