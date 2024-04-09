import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:b_encode_decode/b_encode_decode.dart';
import 'package:dtorrent_common/dtorrent_common.dart';
import 'package:dtorrent_task/dtorrent_task.dart';
import 'package:dtorrent_task/src/peer/peer_events.dart';
import 'package:events_emitter2/events_emitter2.dart';
import 'package:utp_protocol/utp_protocol.dart';

import 'congestion_control.dart';
import 'speed_calculator.dart';
import 'extended_processor.dart';

const keepAliveMessage = [0, 0, 0, 0];
const reservedConst = [0, 0, 0, 0, 0, 0, 0, 0];
const handshakeHead = [
  19,
  66,
  105,
  116,
  84,
  111,
  114,
  114,
  101,
  110,
  116,
  32,
  112,
  114,
  111,
  116,
  111,
  99,
  111,
  108
];

const chokeID = 0;
const unchokeID = 1;
const interestedID = 2;
const notInterestedID = 3;
const haveID = 4;
const bitfieldID = 5;
const requestID = 6;
const pieceID = 7;
const canselID = 8;
const portID = 9;
const extendedID = 20;

const haveAllOP = 0x0e;
const haveNoneOP = 0x0f;
const suggestPieceOP = 0x0d;
const rejectRequestOP = 0x10;
const allowFastOP = 0x11;

// ignore: constant_identifier_names
enum PeerType { TCP, UTP }

/// 30 Seconds
const defaultConnectTimeout = 30;

enum PeerSource { tracker, dht, pex, lsd, incoming, manual, holepunch }

abstract class Peer
    with
        EventsEmittable<PeerEvent>,
        ExtendedProcessor,
        CongestionControl,
        SpeedCalculator {
  /// Countdown time , when peer don't receive or send any message from/to remote ,
  /// this class will invoke close.
  /// Unit: second
  int countdownTime = 150;

  String get id {
    return address.toContactEncodingString();
  }

  /// The total number of pieces of downloaded items
  final int _piecesNum;

  /// Remote Bitfield
  Bitfield? _remoteBitfield;

  /// Whether the peer has been disposed
  bool _disposed = false;

  /// Countdown to close Timer.
  Timer? _countdownTimer;

  /// Whether the other party choke me, the initial default is true
  bool _chokeMe = true;

  /// Did I choke the other party, the default is true
  bool chokeRemote = true;

  /// Whether the other party is interested in my resources, the default is false
  bool _interestedMe = false;

  /// Am I interested in the resources of the other party, the default is false
  bool interestedRemote = false;

  /// Debug use
  // ignore: unused_field
  dynamic _disposeReason;

  /// The address and port of the remote peer
  final CompactAddress address;

  /// Torrent infohash buffer
  final List<int> _infoHashBuffer;

  /// Local Peer Id
  final String
      _localPeerId; // The local peer ID. It is used when sending messages.

  String? _remotePeerId;

  /// has this peer send handshake message already?
  bool _handShaked = false;

  /// has this peer send local bitfield to remote?
  bool _bitfieldSended = false;

  /// Remote data reception, listening to subscription.
  StreamSubscription? _streamChunk;

  /// Buffer to obtain data from the channel.
  List<int> _cacheBuffer = [];

  /// The local sends a request buffer. The format is: [index, begin, length].
  final _requestBuffer = <List<int>>[];

  /// The remote sends a request buffer. The format is: [index, begin, length].
  final _remoteRequestBuffer = <List<int>>[];

  /// Max request count in one piple ,5
  static const maxRequestCount = 5;

  bool remoteEnableFastPeer = false;

  bool localEnableFastPeer = true;

  bool remoteEnableExtended = false;

  bool localEnableExtended = true;

  /// Local Allow Fast pieces.
  final Set<int> _allowFastPieces = <int>{};

  /// Remote Allow Fast pieces.
  final Set<int> _remoteAllowFastPieces = <int>{};

  /// Remote Suggest pieces.
  final Set<int> _remoteSuggestPieces = <int>{};

  final PeerType type;

  final PeerSource source;

  int reqq;

  int? remoteReqq;

  /// [_id] is used to differentiate between different peers. It is different from
  ///  [_localPeerId], which is the Peer_id in the BitTorrent protocol.
  /// [address] is the remote peer's address and port, and subclasses can use this
  ///  value for remote connections.
  /// [_infoHashBuffer] is the infohash value from the torrent file,
  /// and [_piecesNum] is the total number of pieces in the download project,
  /// which is used to construct the remote `Bitfield` data.
  /// The optional parameter [localEnableFastPeer] is set to `true` by default,
  /// indicating whether local peers can use the
  /// [Fast Extension (BEP 0006)](http://www.bittorrent.org/beps/bep_0006.html).
  /// [localEnableExtended] indicates whether local peers can use the
  /// [Extension Protocol](http://www.bittorrent.org/beps/bep_0010.html).
  Peer(this._localPeerId, this.address, this._infoHashBuffer, this._piecesNum,
      this.source,
      {this.type = PeerType.TCP,
      this.localEnableFastPeer = true,
      this.localEnableExtended = true,
      this.reqq = 100}) {
    _remoteBitfield = Bitfield.createEmptyBitfield(_piecesNum);
  }

  factory Peer.newTCPPeer(
      String localPeerId,
      CompactAddress address,
      List<int> infoHashBuffer,
      int piecesNum,
      Socket? socket,
      PeerSource source,
      {bool enableExtend = true,
      bool enableFast = true}) {
    return _TCPPeer(
        localPeerId, address, infoHashBuffer, piecesNum, socket, source,
        enableExtend: enableExtend, enableFast: enableFast);
  }

  factory Peer.newUTPPeer(
      String localPeerId,
      CompactAddress address,
      List<int> infoHashBuffer,
      int piecesNum,
      UTPSocket? socket,
      PeerSource source,
      {bool enableExtend = true,
      bool enableFast = true}) {
    return _UTPPeer(
        localPeerId, address, infoHashBuffer, piecesNum, socket, source,
        enableExtend: enableExtend, enableFast: enableFast);
  }

  /// The remote peer's bitfield.
  Bitfield? get remoteBitfield => _remoteBitfield;

  /// Whether the local bitfield has been sent to the remote peer.
  bool get bitfieldSended => _bitfieldSended;

  bool get isLeecher => !isSeeder;

  /// If it has the complete torrent file, then it is a seeder.
  bool get isSeeder {
    if (_remoteBitfield == null) return false;
    if (_remoteBitfield!.haveAll()) return true;
    return false;
  }

  String? get remotePeerId => _remotePeerId;

  String get localPeerId => _localPeerId;

  /// Requests received from the remote peer.
  List<List<int>> get remoteRequestBuffer => _remoteRequestBuffer;

  /// Requests sent from the local peer to the remote peer.
  List<List<int>> get requestBuffer => _requestBuffer;

  Set<int> get remoteSuggestPieces => _remoteSuggestPieces;

  bool get isDisposed => _disposed;

  bool get chokeMe => _chokeMe;

  set chokeMe(bool c) {
    if (c != _chokeMe) {
      _chokeMe = c;
      events.emit(PeerChokeChanged(this, _chokeMe));
    }
  }

  bool? remoteHave(int index) {
    return _remoteBitfield?.getBit(index);
  }

  bool get interestedMe => _interestedMe;

  set interestedMe(bool i) {
    if (i != _interestedMe) {
      _interestedMe = i;
      events.emit(PeerInterestedChanged(this, _interestedMe));
    }
  }

  /// All completed pieces of the remote peer.
  List<int> get remoteCompletePieces {
    if (_remoteBitfield == null) return [];
    return _remoteBitfield!.completedPieces;
  }

  /// Connect remote peer
  Future connect([int timeout = defaultConnectTimeout]) async {
    try {
      _init();
      var stream = await connectRemote(timeout);
      startSpeedCalculator();
      _streamChunk = stream?.listen(_processReceiveData, onDone: () {
        _log('Connection is closed $address');
        dispose(BadException('The remote peer closed the connection'));
      }, onError: (e) {
        _log('Error happen: $address', e);
        dispose(e);
      });
      events.emit(PeerConnected(this));
    } catch (e) {
      if (e is TCPConnectException) return dispose(e);
      return dispose(BadException(e));
    }
  }

  /// Initialize some basic data.
  void _init() {
    /// Initialize data.
    _disposeReason = null;
    _disposed = false;
    _handShaked = false;

    /// Clear the channel data cache.
    _cacheBuffer.clear();

    /// Clear the request cache.
    _requestBuffer.clear();
    _remoteRequestBuffer.clear();

    /// Reset the fast pieces.
    _remoteAllowFastPieces.clear();
    _allowFastPieces.clear();

    /// Reset the suggest pieces.
    _remoteSuggestPieces.clear();

    /// Reset the remote fast extension flag.
    remoteEnableFastPeer = false;
  }

  List<int>? removeRequest(int index, int begin, int length) {
    var request = _removeRequestFromBuffer(index, begin, length);
    return request;
  }

  /// Add a request to the buffer.

  /// This request is an array:
  /// - 0: index
  /// - 1: begin
  /// - 2: length
  /// - 3: send time
  /// - 4: resend times
  bool addRequest(int index, int begin, int length) {
    var maxCount = currentWindow;
    // maxCount = oldCount;
    if (remoteReqq != null) maxCount = min(remoteReqq!, maxCount);
    if (_requestBuffer.length >= maxCount) return false;
    _requestBuffer
        .add([index, begin, length, DateTime.now().microsecondsSinceEpoch, 0]);
    return true;
  }

  bool get isSleeping {
    return _requestBuffer.isEmpty;
  }

  bool get isDownloading {
    return _requestBuffer.isNotEmpty;
  }

  void _processReceiveData(dynamic data) {
    // Regardless of what message is received, as long as it is not empty, reset the countdown timer.
    if (data != null && data.isNotEmpty) _startToCountdown();
    // if (data.isNotEmpty) log('Received data: $data');
    if (data != null) {
      _cacheBuffer.addAll(
          data); // Accept data sent by the remote peer and buffer it in one place.
    }
    if (_cacheBuffer.isEmpty) return;
    // Check if it's a handshake header.
    if (_cacheBuffer[0] == 19 && _cacheBuffer.length >= 68) {
      if (_isHandShakeHead(_cacheBuffer)) {
        if (_validateInfoHash(_cacheBuffer)) {
          var handshakeBuffer = Uint8List(68);
          List.copyRange(handshakeBuffer, 0, _cacheBuffer, 0, 68);
          _cacheBuffer = _cacheBuffer.sublist(68);
          Timer.run(() => _processHandShake(handshakeBuffer));
          if (_cacheBuffer.isNotEmpty) {
            Timer.run(() => _processReceiveData(null));
          }
          return;
        } else {
          // If infohash buffer is incorrect , dispose this peer
          dispose('Infohash is incorrect');
          return;
        }
      }
    }
    if (_cacheBuffer.length >= 4) {
      var start = 0;
      var lengthBuffer = Uint8List(4);
      List.copyRange(lengthBuffer, 0, _cacheBuffer, start, 4);
      var length = ByteData.view(lengthBuffer.buffer).getInt32(0, Endian.big);
      List<Uint8List>? piecesMessage;
      List<Uint8List>? haveMessages;
      while (_cacheBuffer.length - start - 4 >= length) {
        if (length == 0) {
          Timer.run(() => _processMessage(null, null));
        } else {
          var messageBuffer = Uint8List(length - 1);
          var id = _cacheBuffer[start + 4];
          List.copyRange(
              messageBuffer, 0, _cacheBuffer, start + 5, start + 4 + length);
          switch (id) {
            case pieceID:
              piecesMessage ??= <Uint8List>[];
              piecesMessage.add(messageBuffer);
              break;
            case haveID:
              haveMessages ??= <Uint8List>[];
              haveMessages.add(messageBuffer);
              break;
            default:
              Timer.run(() => _processMessage(id, messageBuffer));
          }
        }
        start += (length + 4);
        if (_cacheBuffer.length - start < 4) break;
        List.copyRange(lengthBuffer, 0, _cacheBuffer, start, start + 4);
        length = ByteData.view(lengthBuffer.buffer).getInt32(0, Endian.big);
      }
      if (piecesMessage != null && piecesMessage.isNotEmpty) {
        Timer.run(() => _processReceivePieces(piecesMessage!));
      }
      if (haveMessages != null && haveMessages.isNotEmpty) {
        Timer.run(() => _processHave(haveMessages!));
      }
      if (start != 0) _cacheBuffer = _cacheBuffer.sublist(start);
    }
  }

  bool _isHandShakeHead(buffer) {
    if (buffer.length < 68) return false;
    for (var i = 0; i < 20; i++) {
      if (buffer[i] != handshakeHead[i]) return false;
    }
    return true;
  }

  bool _validateInfoHash(buffer) {
    for (var i = 28; i < 48; i++) {
      if (buffer[i] != _infoHashBuffer[i - 28]) return false;
    }
    return true;
  }

  void _processMessage(int? id, Uint8List? message) {
    if (id == null) {
      _log('process keep alive $address');
      events.emit(PeerKeepAlive());
      return;
    } else {
      switch (id) {
        case chokeID:
          _log('remote choke me : $address');
          chokeMe = true; // choke message
          return;
        case unchokeID:
          _log('remote unchoke me : $address');
          chokeMe = false; // unchoke message
          return;
        case interestedID:
          _log('remote interested me : $address');
          interestedMe = true;
          return; // interested message
        case notInterestedID:
          _log('remote not interested me : $address');
          interestedMe = false;
          return; // not interested message
        // case ID_HAVE:
        //   _log('process have from : $address');
        //   var index = ByteData.view(message.buffer).getUint32(0);
        //   _processHave(index);
        //   return; // have message
        case bitfieldID:
          // log('process bitfield from $address');
          if (message != null) initRemoteBitfield(message);
          return; // bitfield message
        case requestID:
          _log('process request from $address');
          if (message != null) _processRemoteRequest(message);
          return; // request message
        // case ID_PIECE:
        //   _log('process pieces : $address');
        //   _processReceivePiece(message);
        //   return; // pieces message
        case canselID:
          _log('process cancel : $address');
          if (message != null) _processCancel(message);
          return; // cancel message
        case portID:
          _log('process port : $address');
          if (message != null) {
            var port = ByteData.view(message.buffer).getUint16(0);
            _processPortChange(port);
          }
          return; // port message
        case haveAllOP:
          _log('process have all : $address');
          _processHaveAll();
          return;
        case haveNoneOP:
          _log('process have none : $address');
          _processHaveNone();
          return;
        case suggestPieceOP:
          _log('process suggest pieces : $address');
          if (message != null) _processSuggestPiece(message);
          return;
        case rejectRequestOP:
          _log('process reject request : $address');
          if (message != null) _processRejectRequest(message);
          return;
        case allowFastOP:
          _log('process allow fast : $address');
          if (message != null) _processAllowFast(message);
          return;
        case extendedID:
          if (message != null) {
            var extensionId = message[0];
            message = message.sublist(1);
            processExtendMessage(extensionId, message);
          }
          return;
      }
    }
    _log('Cannot process the message', 'Unknown message : $message');
  }

  /// Remove a request from the request buffer.
  ///
  /// This method is called whenever a piece response is received or a request times out.
  List<int>? _removeRequestFromBuffer(int index, int begin, int length) {
    var i = _findRequestIndexFromBuffer(index, begin, length);
    if (i != -1) {
      return _requestBuffer.removeAt(i);
    }
    return null;
  }

  int _findRequestIndexFromBuffer(int index, int begin, int length) {
    for (var i = 0; i < _requestBuffer.length; i++) {
      var r = _requestBuffer[i];
      if (r[0] == index && r[1] == begin) {
        return i;
      }
    }
    return -1;
  }

  @override
  void processExtendHandshake(data) {
    if (data['reqq'] != null && data['reqq'] is int) {
      remoteReqq = data['reqq'];
    }
    super.processExtendHandshake(data);
  }

  void sendExtendMessage(String name, List<int> data) {
    var id = getExtendedEventId(name);
    if (id != null) {
      var message = <int>[];
      message.add(id);
      message.addAll(data);
      sendMessage(extendedID, message);
    }
  }

  void _processCancel(Uint8List message) {
    var view = ByteData.view(message.buffer);
    var index = view.getUint32(0);
    var begin = view.getUint32(4);
    var length = view.getUint32(8);
    int? requestIndex;
    for (var i = 0; i < _remoteRequestBuffer.length; i++) {
      var r = _remoteRequestBuffer[i];
      if (r[0] == index && r[1] == begin) {
        requestIndex = i;
        break;
      }
    }
    if (requestIndex != null) {
      _remoteRequestBuffer.removeAt(requestIndex);
      events.emit(PeerCancelEvent(index, begin, length));
    }
  }

  void _processPortChange(int port) {
    if (address.port == port) return;
    events.emit(PeerPortChanged(port));
  }

  void _processHaveAll() {
    if (!remoteEnableFastPeer) {
      dispose('Remote disabled fast extension but receive \'have all\'');
      return;
    }
    if (_remoteBitfield == null) return;
    for (var i = 0; i < _remoteBitfield!.buffer.length - 1; i++) {
      _remoteBitfield?.buffer[i] = 255;
    }
    var index = _remoteBitfield!.buffer.length - 1;
    index = index * 8;
    for (var i = index; i < _remoteBitfield!.piecesNum; i++) {
      _remoteBitfield?.setBit(i, true);
    }

    events.emit(PeerHaveAll(this));
  }

  void _processHaveNone() {
    if (!remoteEnableFastPeer) {
      dispose('Remote disabled fast extension but receive \'have none\'');
      return;
    }
    _remoteBitfield = Bitfield.createEmptyBitfield(_piecesNum);
    events.emit(PeerHaveNone(this));
  }

  ///
  /// When the fast extension is disabled, if a peer receives a Suggest Piece message,
  /// the peer MUST close the connection.
  void _processSuggestPiece(Uint8List message) {
    if (!remoteEnableFastPeer) {
      dispose('Remote disabled fast extension but receive \'suggest piece\'');
      return;
    }
    var view = ByteData.view(message.buffer);
    var index = view.getUint32(0);
    if (_remoteSuggestPieces.add(index)) {
      events.emit(PeerSuggestPiece(this, index));
    }
  }

  void _processRejectRequest(Uint8List message) {
    if (!remoteEnableFastPeer) {
      dispose('Remote disabled fast extension but receive \'reject request\'');
      return;
    }

    var view = ByteData.view(message.buffer);
    var index = view.getUint32(0);
    var begin = view.getUint32(4);
    var length = view.getUint32(8);
    if (removeRequest(index, begin, length) != null) {
      startRequestDataTimeout();
      events.emit(PeerRejectEvent(index, begin, length));
    } else {
      // It's possible that the peer was deleted, but the reject message arrived too late.
      // dispose('Never send request ($index,$begin) but receive a rejection');
      return;
    }
  }

  void _processAllowFast(Uint8List message) {
    if (!remoteEnableFastPeer) {
      dispose('Remote disabled fast extension but receive \'allow fast\'');
      return;
    }
    var view = ByteData.view(message.buffer);
    var index = view.getUint32(0);
    if (_remoteAllowFastPieces.add(index)) {
      events.emit(PeerAllowFast(this, index));
    }
  }

  /// When the fast extension is enabled:
  ///
  /// - If a peer receives a request from a peer its choking, the peer receiving the
  /// request SHOULD send a reject unless the piece is in the allowed fast set.
  /// - If a peer receives an excessive number of requests from a peer it is choking,
  /// the peer receiving the requests MAY close the connection rather than reject the request.
  /// However, consider that it can take several seconds for buffers to drain and messages to propagate once a peer is choked.
  void _processRemoteRequest(Uint8List message) {
    if (_remoteRequestBuffer.length > reqq) {
      dev.log('Request Error:',
          error: 'Too many requests from $address',
          name: runtimeType.toString());
      dispose(BadException('Too many requests from $address'));
      return;
    }
    var view = ByteData.view(message.buffer);
    var index = view.getUint32(0);
    var begin = view.getUint32(4);
    var length = view.getUint32(8);
    if (length > maxRequestLength) {
      dev.log('TOO LARGEt BLOCK',
          error: 'BLOCK $length', name: runtimeType.toString());
      dispose(BadException(
          '$address : request block length larger than limit : $length > $maxRequestLength'));
      return;
    }
    if (chokeRemote) {
      if (_allowFastPieces.contains(index)) {
        _remoteRequestBuffer.add([index, begin, length]);
        events.emit(PeerRequestEvent(this, index, begin, length));
        return;
      } else {
        // Choking the remote peer without sending an acknowledgment.
        // sendRejectRequest(index, begin, length);
        return;
      }
    }

    _remoteRequestBuffer.add([index, begin, length]);
    // TODO Implement speed limit here!
    events.emit(PeerRequestEvent(this, index, begin, length));
  }

  /// Handle the received PIECE messages.
  ///
  /// Unlike other message types, PIECE messages are processed in batches.
  void _processReceivePieces(List<Uint8List> messages) {
    var requests = <List<int>>[];
    for (var message in messages) {
      var dataHead = Uint8List(8);
      List.copyRange(dataHead, 0, message, 0, 8);
      var view = ByteData.view(dataHead.buffer);
      var index = view.getUint32(0);
      var begin = view.getUint32(4);
      var blockLength = message.length - 8;
      var request = removeRequest(index, begin, blockLength);

      /// Ignore if there are no requests to process.
      if (request == null) {
        continue;
      }
      var block = Uint8List(message.length - 8);
      List.copyRange(block, 0, message, 8);
      requests.add(request);
      _log(
          'Received request for Piece ($index, $begin) content, downloaded $downloaded bytes from the current Peer $type $address');
      events.emit(PeerPieceEvent(this, index, begin, block));
    }
    messages.clear();
    ackRequest(requests);
    updateDownload(requests);
    startRequestDataTimeout();
  }

  void _processHave(List<Uint8List> messages) {
    var indices = <int>[];
    for (var message in messages) {
      var index = ByteData.view(message.buffer).getUint32(0);
      indices.add(index);
      updateRemoteBitfield(index, true);
    }
    events.emit(PeerHaveEvent(this, indices));
  }

  /// Update the remote peer's bitfield.
  void updateRemoteBitfield(int index, bool have) {
    _remoteBitfield?.setBit(index, have);
  }

  void initRemoteBitfield(Uint8List bitfield) {
    _remoteBitfield = Bitfield(_piecesNum, bitfield);
    // Bitfield.copyFrom(_piecesNum, bitfield, 1);
    events.emit(PeerBitfieldEvent(this, _remoteBitfield));
  }

  void _processHandShake(List<int> data) {
    _remotePeerId = _parseRemotePeerId(data);
    var reserved = data.getRange(20, 28);
    var fast = reserved.elementAt(7) & 0x04;
    remoteEnableFastPeer = (fast == 0x04);
    var extended = reserved.elementAt(5);
    remoteEnableExtended = ((extended & 0x10) == 0x10);
    _sendExtendedHandshake();
    events.emit(PeerHandshakeEvent(this, _remotePeerId!, data));
  }

  void _sendExtendedHandshake() async {
    if (localEnableExtended && remoteEnableExtended) {
      var m = await _createExtendedHandshakeMessage();
      sendMessage(extendedID, m);
    }
  }

  String _parseRemotePeerId(List<int> data) {
    return String.fromCharCodes(data.sublist(48, 68));
  }

  /// Connect remote peer and return a [Stream] future
  ///
  /// [timeout] default value is 30 seconds
  /// Different type peer use different protocol , such as TCP,uTP,
  /// so this method should be implemented by sub-class
  Future<Stream?> connectRemote(int timeout);

  /// Send message to remote
  ///
  /// this method will transform the [message] and id to be the peer protocol message bytes
  void sendMessage(int? id, [List<int>? message]) {
    if (isDisposed) return;
    if (id == null) {
      // it's keep alive
      sendByteMessage(keepAliveMessage);
      _startToCountdown();
      return;
    }
    var m = _createByteMessage(id, message);
    sendByteMessage(m);
    _startToCountdown();
  }

  List<int> _createByteMessage(int id, List<int>? message) {
    var length = 0;
    if (message != null) length = message.length;
    length = length + 1;
    var datas = List<int>.filled(length + 4, 0);
    var head = Uint8List(4);
    var view1 = ByteData.view(head.buffer);
    view1.setUint32(0, length, Endian.big);
    List.copyRange(datas, 0, head);
    datas[4] = id;
    if (message != null && message.isNotEmpty) {
      List.copyRange(datas, 5, message);
    }
    return datas;
  }

  /// Send the message buffer to remote
  ///
  /// See : [Peer protocol message](https://wiki.theory.org/BitTorrentSpecification#Messages)
  void sendByteMessage(List<int> bytes);

  /// Send a handshake message.
  ///
  /// After sending the handshake message, this method will also proactively send the bitfield and have messages to the remote peer.
  void sendHandShake() {
    if (_handShaked) return;
    var message = <int>[];
    message.addAll(handshakeHead);
    var reserved = List<int>.from(reservedConst);
    if (localEnableFastPeer) {
      reserved[7] |= 0x04;
    }
    if (localEnableExtended) {
      reserved[5] |= 0x10;
    }
    message.addAll(reserved);
    message.addAll(_infoHashBuffer);
    message.addAll(utf8.encode(_localPeerId));
    sendByteMessage(message);
    _startToCountdown();
    _handShaked = true;
  }

  Future<List<int>> _createExtendedHandshakeMessage() async {
    var message = <int>[];
    message.add(0);
    var d = <String, dynamic>{};
    d['yourip'] = address.address.rawAddress;
    var version = await getTorrentTaskVersion();
    version ??= '0.0.0';
    d['v'] = 'Dart BT v$version';
    d['m'] = localExtended;
    d['reqq'] = reqq;
    var m = encode(d);
    message.addAll(m);
    return message;
  }

  /// `keep-alive: <len=0000>`
  ///
  /// The `keep-alive` message is a message with zero bytes, specified with the length prefix set to zero.
  /// There is no message ID and no payload. Peers may close a connection if they receive no messages
  /// (keep-alive or any other message) for a certain period of time, so a keep-alive message must be
  /// sent to maintain the connection alive if no command have been sent for a given amount of time.
  /// This amount of time is generally two minutes.
  void sendKeepAlive() {
    sendMessage(null);
  }

  /// `piece: <len=0009+X><id=7><index><begin><block>`
  ///
  /// The `piece` message is variable length, where X is the length of the block. The payload contains the following information:
  ///
  /// - index: integer specifying the zero-based piece index
  /// - begin: integer specifying the zero-based byte offset within the piece
  /// - block: block of data, which is a subset of the piece specified by index.
  bool sendPiece(int index, int begin, List<int> block) {
    if (chokeRemote) {
      if (!remoteEnableFastPeer || !_allowFastPieces.contains(index)) {
        return false;
      }
    }
    int? requestIndex;
    for (var i = 0; i < _remoteRequestBuffer.length; i++) {
      var r = _remoteRequestBuffer[i];
      if (r[0] == index && r[1] == begin) {
        requestIndex = i;
        break;
      }
    }
    if (requestIndex == null) {
      return false;
    }
    _remoteRequestBuffer.removeAt(requestIndex);
    var bytes = <int>[];
    var messageHead = Uint8List(8);
    var view = ByteData.view(messageHead.buffer);
    view.setUint32(0, index, Endian.big);
    view.setUint32(4, begin, Endian.big);
    bytes.addAll(messageHead);
    bytes.addAll(block);
    sendMessage(pieceID, bytes);
    updateUpload(bytes.length);
    return true;
  }

  @override
  void timeOutErrorHappen() {
    dispose('BADTIMEOUT');
  }

  /// `request: <len=0013><id=6><index><begin><length>`
  ///
  /// The `request` message is fixed length, and is used to request a block.
  /// The payload contains the following information:
  ///
  /// - [index]: integer specifying the zero-based piece index
  /// - [begin]: integer specifying the zero-based byte offset within the piece
  /// - [length]: integer specifying the requested length.
  /// - [timeout]: when send request to remote , after [timeout] of not getting response,
  /// it will fire [requestTimeout] event
  bool sendRequest(int index, int begin, [int length = defaultRequestLength]) {
    if (_chokeMe) {
      if (!remoteEnableFastPeer || !_remoteAllowFastPieces.contains(index)) {
        return false;
      }
    }

    if (!addRequest(index, begin, length)) {
      return false;
    }
    _sendRequestMessage(index, begin, length);
    startRequestDataTimeout();
    return true;
  }

  void _sendRequestMessage(int index, int begin, int length) {
    var bytes = Uint8List(12);
    var view = ByteData.view(bytes.buffer);
    view.setUint32(0, index, Endian.big);
    view.setUint32(4, begin, Endian.big);
    view.setUint32(8, length, Endian.big);
    sendMessage(requestID, bytes);
  }

  @override
  List<List<int>> get currentRequestBuffer => _requestBuffer;

  /// Cancel a specific request by removing it from the request queue.
  ///
  /// If the request is present in the queue, it will be removed; otherwise, this operation will simply return.
  void requestCancel(int index, int begin, int length) {
    var request = removeRequest(index, begin, length);
    if (request != null) {
      _sendCancel(index, begin, length);
    }
  }

  @override
  void orderResendRequest(int index, int begin, int length, int resend) {
    _requestBuffer.add([
      index,
      begin,
      length,
      DateTime.now().microsecondsSinceEpoch,
      resend + 1
    ]);
  }

  /// `bitfield: <len=0001+X><id=5><bitfield>`
  ///
  /// The `bitfield` message may only be sent immediately after the handshaking sequence is completed,
  /// and before any other messages are sent. It is optional, and need not be sent if a client has no pieces.
  /// However,if no pieces to send and remote peer enable fast extension, it will send `Have None` message,
  /// and if have all pieces, it will send `Have All` message instead of bitfield buffer.
  ///
  /// The `bitfield` message is variable length, where X is the length of the bitfield. The payload is a
  /// bitfield representing the pieces that have been successfully downloaded. The high bit in the first byte
  /// corresponds to piece index 0. Bits that are cleared indicated a missing piece, and set bits indicate a
  /// valid and available piece. Spare bits at the end are set to zero.
  ///
  void sendBitfield(Bitfield bitfield) {
    _log('Sending bitfile information to the peer: ${bitfield.buffer}');
    if (_bitfieldSended) return;
    _bitfieldSended = true;
    if (remoteEnableFastPeer && localEnableFastPeer) {
      if (bitfield.haveNone()) {
        sendHaveNone();
      } else if (bitfield.haveAll()) {
        sendHaveAll();
      } else {
        sendMessage(bitfieldID, bitfield.buffer);
      }
    } else if (bitfield.haveCompletePiece()) {
      sendMessage(bitfieldID, bitfield.buffer);
    }
  }

  /// `have: <len=0005><id=4><piece index>`
  ///
  /// The `have` message is fixed length. The payload is the zero-based
  /// index of a piece that has just been successfully downloaded and verified via the hash.
  void sendHave(int index) {
    var bytes = Uint8List(4);
    _log('Sending have information to the peer: $bytes, $index');
    ByteData.view(bytes.buffer).setUint32(0, index, Endian.big);
    sendMessage(haveID, bytes);
  }

  /// - `choke: <len=0001><id=0>`
  /// - `unchoke: <len=0001><id=1>`
  ///
  /// The `choke`/`unchoke` message is fixed-length and has no payload.
  void sendChoke(bool choke) {
    if (chokeRemote == choke) {
      return;
    }
    chokeRemote = choke;
    var id = chokeID;
    if (!choke) id = unchokeID;
    sendMessage(id);
  }

  ///Send interested or not interested to the other party to indicate whether you are interested in its resources or not.
  ///
  /// - `interested: <len=0001><id=2>`
  /// - `not interested: <len=0001><id=3>`
  ///
  /// The `interested`/`not interested` message is fixed-length and has no payload.
  void sendInterested(bool iamInterested) {
    if (interestedRemote == iamInterested) {
      return;
    }
    interestedRemote = iamInterested;
    var id = interestedID;
    if (!iamInterested) id = notInterestedID;
    sendMessage(id);
  }

  /// `cancel: <len=0013><id=8><index><begin><length>`
  ///
  /// The `cancel` message is fixed length, and is used to cancel block requests.
  /// The payload is identical to that of the "request" message. It is typically used during "End Game"
  void _sendCancel(int index, int begin, int length) {
    var bytes = Uint8List(12);
    var view = ByteData.view(bytes.buffer);
    view.setUint32(0, index, Endian.big);
    view.setUint32(4, begin, Endian.big);
    view.setUint32(8, length, Endian.big);
    sendMessage(canselID, bytes);
  }

  /// `port: <len=0003><id=9><listen-port>`
  ///
  /// The [port] message is sent by newer versions of the Mainline that implements a DHT tracker.
  /// The listen port is the port this peer's DHT node is listening on. This peer should be
  /// inserted in the local routing table (if DHT tracker is supported).
  void sendPortChange(int port) {
    var bytes = Uint8List(2);
    ByteData.view(bytes.buffer).setUint16(0, port);
    sendMessage(portID, bytes);
  }

  /// BEP 0006
  ///
  /// Have all message
  void sendHaveAll() {
    if (remoteEnableFastPeer && localEnableFastPeer) {
      sendMessage(haveAllOP);
    }
  }

  /// BEP 0006
  ///
  /// Have none message
  void sendHaveNone() {
    if (remoteEnableFastPeer && localEnableFastPeer) {
      sendMessage(haveNoneOP);
    }
  }

  /// BEP 0006
  /// `*Suggest Piece*: <len=0x0005><op=0x0D><index>`
  ///
  /// `Suggest Piece` is an advisory message meaning "you might like to download this piece."
  /// The intended usage is for 'super-seeding' without throughput reduction, to avoid redundant
  /// downloads, and so that a seed which is disk I/O bound can upload contiguous or identical
  /// pieces to avoid excessive disk seeks.
  ///
  /// In all cases, the seed SHOULD operate to maintain a roughly equal number of copies of each
  /// piece in the network. A peer MAY send more than one suggest piece message at any given time.
  /// A peer receiving multiple suggest piece messages MAY interpret this as meaning that all of
  /// the suggested pieces are equally appropriate.
  ///
  void sendSuggestPiece(int index) {
    if (remoteEnableFastPeer && localEnableFastPeer) {
      var bytes = Uint8List(4);
      var view = ByteData.view(bytes.buffer);
      view.setUint32(0, index, Endian.big);
      sendMessage(suggestPieceOP, bytes);
    }
  }

  /// BEP 0006
  ///
  /// `*Reject Request*: <len=0x000D><op=0x10><index><begin><length>`
  ///
  /// Reject Request notifies a requesting peer that its request will not be satisfied.
  ///
  void sendRejectRequest(int index, int begin, int length) {
    if (remoteEnableFastPeer && localEnableFastPeer) {
      var bytes = Uint8List(12);
      var view = ByteData.view(bytes.buffer);
      view.setUint32(0, index, Endian.big);
      view.setUint32(4, begin, Endian.big);
      view.setUint32(8, length, Endian.big);
      sendMessage(rejectRequestOP, bytes);
    }
  }

  /// BEP 0006
  ///
  /// `*Allowed Fast*: <len=0x0005><op=0x11><index>`
  ///
  /// `Allowed Fast` is an advisory message which means "if you ask for this piece,
  /// I'll give it to you even if you're choked."
  ///
  /// `Allowed Fast` thus shortens the awkward stage during which the peer obtains occasional
  ///  optimistic unchokes but cannot sufficiently reciprocate to remain unchoked.
  ///
  void sendAllowFast(int index) {
    if (remoteEnableFastPeer && localEnableFastPeer) {
      if (_allowFastPieces.add(index)) {
        var bytes = Uint8List(4);
        var view = ByteData.view(bytes.buffer);
        view.setUint32(0, index, Endian.big);
        sendMessage(allowFastOP, bytes);
      }
    }
  }

  /// Countdown started.
  ///
  /// Over `countdownTime` seconds , peer will close to disconnect the remote.
  /// but if peer send or receive any message from/to remote during countdown,
  /// it will re-countdown.
  void _startToCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer(Duration(seconds: countdownTime), () {
      dispose('Over $countdownTime seconds no communication, close');
    });
  }

  /// The Peer has been disposed.
  ///
  /// After disposal, the Peer will no longer be able to send or receive data, its state data will be reset to its initial state, and all previously added event listeners will be removed.
  Future dispose([dynamic reason]) async {
    if (_disposed) return;
    _disposeReason = reason;
    _disposed = true;
    _handShaked = false;
    _bitfieldSended = false;
    events.emit(PeerDisposeEvent(this, reason));
    events.dispose();
    clearExtendedProcessors();
    clearCC();
    stopSpeedCalculator();
    var re = _streamChunk?.cancel();
    _streamChunk = null;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    return re;
  }

  void _log(String message, [dynamic error]) {
    if (error != null) {
      dev.log(message, error: error, name: runtimeType.toString());
    } else {
      dev.log(message, name: runtimeType.toString());
    }
  }

  @override
  String toString() {
    return '$type:${_remotePeerId?.codeUnits != null ? Uint8List.fromList(_remotePeerId!.codeUnits).toHexString() : ''} $address $source';
  }

  @override
  int get hashCode => address.address.address.hashCode;

  @override
  bool operator ==(other) {
    if (other is Peer) {
      return other.address.address.address == address.address.address;
    }
    return false;
  }
}

class BadException implements Exception {
  final dynamic e;
  BadException(this.e);
  @override
  String toString() {
    return 'No need to reconnect error: $e';
  }
}

class TCPConnectException implements Exception {
  // ignore: unused_field
  final Exception _e;
  TCPConnectException(this._e);
}

class _TCPPeer extends Peer {
  Socket? _socket;
  _TCPPeer(String localPeerId, CompactAddress address, List<int> infoHashBuffer,
      int piecesNum, this._socket, PeerSource source,
      {bool enableExtend = true, bool enableFast = true})
      : super(localPeerId, address, infoHashBuffer, piecesNum, source,
            type: PeerType.TCP,
            localEnableExtended: enableExtend,
            localEnableFastPeer: enableFast);

  @override
  Future<Stream?> connectRemote(int? timeout) async {
    timeout ??= 30;
    try {
      _socket ??= await Socket.connect(address.address, address.port,
          timeout: Duration(seconds: timeout));
      return _socket;
    } on Exception catch (e) {
      throw TCPConnectException(e);
    }
  }

  @override
  void sendByteMessage(List<int> bytes) {
    try {
      _socket?.add(bytes);
    } catch (e) {
      dispose(e);
    }
  }

  @override
  Future<void> dispose([reason]) async {
    try {
      await _socket?.close();
      _socket = null;
    } catch (e) {
      // do nothing
    } finally {
      super.dispose(reason);
    }
  }
}

/// TODO :
///
/// Currently , each uTP Peer use a single UTPSocketClient,
/// actually , one UTPSocketClient should maintain several uTP socket(uTP peer),
/// this class need to improve.
class _UTPPeer extends Peer {
  UTPSocketClient? _client;
  UTPSocket? _socket;
  _UTPPeer(
    String localPeerId,
    CompactAddress address,
    List<int> infoHashBuffer,
    int piecesNum,
    this._socket,
    PeerSource source, {
    bool enableExtend = true,
    bool enableFast = true,
  }) : super(localPeerId, address, infoHashBuffer, piecesNum, source,
            type: PeerType.UTP,
            localEnableExtended: enableExtend,
            localEnableFastPeer: enableFast);

  @override
  Future<Stream?> connectRemote(int timeout) async {
    if (_socket != null) return _socket;
    _client ??= UTPSocketClient();
    _socket = await _client?.connect(address.address, address.port);
    return _socket;
  }

  @override
  void sendByteMessage(List<int> bytes) {
    _socket?.add(bytes);
  }

  @override
  Future dispose([reason]) async {
    await _socket?.close();
    await _client?.close();
    return super.dispose(reason);
  }
}
