import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' show sha1;
import 'package:logging/logging.dart';

import 'package:b_encode_decode/b_encode_decode.dart';
import 'package:dart_ipify/dart_ipify.dart';
import 'package:dtorrent_common/dtorrent_common.dart';
import 'package:bittorrent_dht/bittorrent_dht.dart';
import 'package:dtorrent_task/src/metadata/metadata_downloader_events.dart';
import 'package:dtorrent_task/src/peer/protocol/peer_events.dart';
import 'package:dtorrent_tracker/dtorrent_tracker.dart' hide PeerEvent;
import 'package:events_emitter2/events_emitter2.dart';

import '../peer/protocol/peer.dart';
import '../peer/extensions/holepunch.dart';
import '../peer/extensions/pex.dart';
import '../utils.dart';
import 'metadata_messenger.dart';

/// Logger instance for MetadataDownloader
final _log = Logger('MetadataDownloader');

/// Downloads metadata (torrent info dictionary) using the ut_metadata extension.
/// Implements BEP 9 (Metadata Exchange) and integrates with PEX and DHT for peer discovery.
class MetadataDownloader
    with
        Holepunch,
        PEX,
        MetaDataMessenger,
        EventsEmittable<MetadataDownloaderEvent>
    implements AnnounceOptionsProvider {
  /// IP addresses that should be ignored for peer connections
  final List<InternetAddress> ignoreIps = [
    InternetAddress.anyIPv4,
    InternetAddress.loopbackIPv4
  ];

  /// Our external IP address as seen by peers
  InternetAddress? localExternalIP;

  /// Total size of metadata in bytes
  int? _metaDataSize;

  /// Number of metadata blocks (16KiB each, except possibly the last block)
  int? _metaDataBlockNum;

  /// Returns the total size of metadata in bytes
  int? get metaDataSize => _metaDataSize;

  /// Returns number of bytes downloaded so far
  int? get bytesDownloaded =>
      _metaDataSize != null ? _completedPieces.length * 16 * 1024 : 0;

  /// Download progress as percentage (0-100)
  double get progress => _metaDataBlockNum != null
      ? _completedPieces.length / _metaDataBlockNum! * 100
      : 0;

  /// Our peer ID for the BitTorrent protocol
  late String _localPeerId;

  /// Info hash as bytes
  late List<int> _infoHashBuffer;

  /// Info hash as hex string
  final String _infoHashString;

  /// Currently connected peers
  final Set<Peer> _activePeers = {};

  /// Peers that support metadata exchange
  final Set<Peer> _availablePeers = {};

  /// Map of peer event listeners
  final Map<Peer, EventsListener<PeerEvent>> _peerListeners = {};

  /// Set of all known peer addresses
  final Set<CompactAddress> _peersAddress = {};

  /// Set of addresses with incoming connections
  final Set<InternetAddress> _incomingAddress = {};

  /// DHT instance for peer discovery
  final DHT _dht = DHT();
  DHT get dht => _dht;

  /// Whether the downloader is currently running
  bool _running = false;

  /// End of bencoded data marker
  final int E = 'e'.codeUnits[0];

  /// Buffer for storing downloaded metadata pieces
  List<int> _metadataBuffer = [];

  /// Queue of metadata pieces to download
  final Queue<int> _metaDataPieces = Queue();

  /// List of completed piece indices
  final List<int> _completedPieces = [];

  /// Map of request timeouts by peer ID
  final Map<String, Timer> _requestTimeout = {};

  /// Creates a new metadata downloader for the given info hash
  MetadataDownloader(this._infoHashString) {
    _localPeerId = generatePeerId();
    _infoHashBuffer = hexString2Buffer(_infoHashString)!;
    assert(_infoHashBuffer.isNotEmpty && _infoHashBuffer.length == 20,
        'Info Hash String is incorrect');
    _init();
    _log.info('Created MetadataDownloader for hash: $_infoHashString');
  }
  Future<void> _init() async {
    try {
      localExternalIP = InternetAddress.tryParse(await Ipify.ipv4());
      _log.info('External IP detected: $localExternalIP');
    } catch (e) {
      _log.warning('Failed to detect external IP', e);
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
  void addNewPeerAddress(CompactAddress address, PeerSource source,
      [PeerType type = PeerType.TCP, dynamic socket]) {
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
        peer = Peer.newUTPPeer(address, _infoHashBuffer, 0, socket, source);
      }
      if (peer != null) _hookPeer(peer);
    }
  }

  void _hookPeer(Peer peer) {
    if (peer.address.address == localExternalIP) return;
    if (_peerExist(peer)) return;
    _peerListeners[peer] = peer.createListener();
    _peerListeners[peer]!
      ..on<PeerDisposeEvent>(
          (event) => _processPeerDispose(event.peer, event.reason))
      ..on<PeerHandshakeEvent>((event) =>
          _processPeerHandshake(event.peer, event.remotePeerId, event.data))
      ..on<PeerConnected>((event) => _peerConnected(event.peer))
      ..on<ExtendedEvent>((event) =>
          _processExtendedMessage(peer, event.eventName, event.data));
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
    _log.fine('Received extended message "$name" from peer ${peer.address}');

    if (name == 'ut_metadata' && data is Uint8List) {
      _log.fine('Processing metadata message from peer ${peer.address}');
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
        _log.info('Received metadata size: $_metaDataSize bytes');
        _metadataBuffer = List.filled(_metaDataSize!, 0);
        _metaDataBlockNum = _metaDataSize! ~/ (16 * 1024);
        if (_metaDataBlockNum! * (16 * 1024) != _metaDataSize) {
          _metaDataBlockNum = _metaDataBlockNum! + 1;
        }
        for (var i = 0; i < _metaDataBlockNum!; i++) {
          _metaDataPieces.add(i);
        }
      }

      if (localExternalIP != null &&
          data['yourip'] != null &&
          (data['yourip'].length == 4 || data['yourip'].length == 16)) {
        InternetAddress myIp;
        try {
          myIp = InternetAddress.fromRawAddress(data['yourip']);
        } catch (e) {
          return;
        }
        if (ignoreIps.contains(myIp)) return;
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
    if (_completedPieces.length >= _metaDataBlockNum! ||
        _completedPieces.contains(piece)) {
      _log.warning('Duplicate or late piece $piece received, ignoring');
      return;
    }

    _log.info(
        'Piece $piece downloaded (${_completedPieces.length + 1}/$_metaDataBlockNum)');

    var pieceOffset = piece * 16 * 1024;
    List.copyRange(_metadataBuffer, pieceOffset, bytes, start);
    _completedPieces.add(piece);

    double currentProgress = progress;
    _log.info('Download progress: ${currentProgress.toStringAsFixed(2)}%');
    events.emit(MetaDataDownloadProgress(currentProgress));

    if (_completedPieces.length >= _metaDataBlockNum!) {
      _log.info('Metadata download complete! Verifying...');
      var digest = sha1.convert(_metadataBuffer);
      var valid = digest.toString() == _infoHashString;
      if (!valid) {
        _log.warning('Metadata verification failed! Hash mismatch.');
        events.emit(MetaDataDownloadFailed('Metadata verification failed'));

        //TODO: Restart metadata download if needed
        // _log.info('Restarting metadata download...');
        // return;
      }
      _log.info('Metadata verified successfully');
      // Emit the complete event with the downloaded metadata
      events.emit(MetaDataDownloadComplete(_metadataBuffer));
      await stop();
      _log.info('Metadata successfully downloaded and verified');
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
  void holePunchConnect(CompactAddress ip) {
    addNewPeerAddress(ip, PeerSource.holepunch, PeerType.UTP);
  }

  @override
  void holePunchError(String err, CompactAddress ip) {}

  @override
  void holePunchRendezvous(CompactAddress ip) {}

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
