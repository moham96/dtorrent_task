import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:dtorrent_parser/dtorrent_parser.dart';
import 'package:dtorrent_task/src/file/download_file_manager_events.dart';
import 'package:dtorrent_task/src/lsd/lsd_events.dart';
import 'package:dtorrent_task/src/peer/peers_manager_events.dart';
import 'package:dtorrent_task/src/task_events.dart';
import 'package:dtorrent_tracker/dtorrent_tracker.dart';
import 'package:dtorrent_common/dtorrent_common.dart';
import 'package:bittorrent_dht/bittorrent_dht.dart';
import 'package:utp_protocol/utp_protocol.dart';
import 'package:events_emitter2/events_emitter2.dart';
import 'file/download_file_manager.dart';
import 'file/state_file.dart';
import 'lsd/lsd.dart';
import 'peer/peer.dart';
import 'piece/base_piece_selector.dart';
import 'piece/piece_manager.dart';
import 'peer/peers_manager.dart';
import 'utils.dart';

const maxPeers = 50;
const maxInPeers = 10;

enum TaskState { running, paused, stopped }

abstract class TorrentTask with EventsEmittable<TaskEvent> {
  factory TorrentTask.newTask(Torrent metaInfo, String savePath,
      [int port = 0]) {
    assert(port <= 65535 && port >= 0,
        'TorrentTask: port must be in range 0 - 65535');
    return _TorrentTask(metaInfo, savePath, port);
  }
  void startAnnounceUrl(Uri url, Uint8List infoHash);
  Torrent get metaInfo;

  // The name of the torrent
  String get name => metaInfo.name;

  // The dht instance

  DHT? get dht;

  int get allPeersNumber;

  int get connectedPeersNumber;

  int get seederNumber;

  /// Current download speed
  double get currentDownloadSpeed;

  /// Current upload speed
  double get uploadSpeed;

  /// Average download speed
  double get averageDownloadSpeed;

  /// Average upload speed
  double get averageUploadSpeed;

  // TODO debug:
  double get utpDownloadSpeed;
  // TODO debug:
  double get utpUploadSpeed;
  // TODO debug:
  int get utpPeerCount;

  /// Downloaded total bytes length
  int? get downloaded;

  /// Downloaded percent
  double get progress;

  /// Start to download
  Future start();

  /// Stop this task
  Future stop();

  abstract TaskState state;
  Iterable<Peer>? get activePeers;

  /// Pause task
  void pause();

  /// Resume task
  void resume();

  void requestPeersFromDHT();

  /// Adding a DHT node usually involves adding the nodes from the torrent file into the DHT network.
  ///
  /// Alternatively, you can directly add known node addresses.
  void addDHTNode(Uri uri);

  /// Add known Peer addresses.
  void addPeer(CompactAddress address, PeerSource source,
      {PeerType? type, Socket socket});
}

class _TorrentTask
    with EventsEmittable<TaskEvent>
    implements TorrentTask, AnnounceOptionsProvider {
  static InternetAddress localAddress =
      InternetAddress.fromRawAddress(Uint8List.fromList([127, 0, 0, 1]));

  TorrentAnnounceTracker? _tracker;

  DHT? _dht = DHT();

  @override
  // The Dht instance
  DHT? get dht => _dht;

  LSD? _lsd;

  StateFile? _stateFile;

  PieceManager? _pieceManager;

  DownloadFileManager? _fileManager;

  PeersManager? _peersManager;

  @override
  Iterable<Peer>? get activePeers => _peersManager?.activePeers;

  final Torrent _metaInfo;
  @override
  Torrent get metaInfo => _metaInfo;

  @override
  String get name => metaInfo.name;

  final String _savePath;

  final Set<String> _peerIds = {};

  late String
      _peerId; // This is the generated local peer ID, which is different from the ID used in the Peer class.

  ServerSocket? _serverSocket;

  StreamSubscription<Socket>? _serverSocketListener;
  // ServerUTPSocket? _utpServer;

  final Set<InternetAddress> _comingIp = {};

  EventsListener<TorrentAnnounceEvent>? trackerListener;
  EventsListener<PeersManagerEvent>? peersManagerListener;
  EventsListener<DownloadFileManagerEvent>? fileManagerListener;
  EventsListener<LSDEvent>? lsdListener;
  EventsListener<DHTEvent>? _dhtListener;

  /// Recommend: 6881-6889
  /// https://wiki.wireshark.org/BitTorrent#:~:text=The%20well%20known%20TCP%20port,6969%20for%20the%20tracker%20port).
  int port;

  _TorrentTask(this._metaInfo, this._savePath, [this.port = 0]) {
    assert(port <= 65535 && port >= 0,
        '_TorrentTask: port must be in range 0 - 65535');
    _peerId = generatePeerId();
  }

  @override
  double get averageDownloadSpeed {
    if (_peersManager != null) {
      return _peersManager!.averageDownloadSpeed;
    } else {
      return 0.0;
    }
  }

  @override
  double get averageUploadSpeed {
    if (_peersManager != null) {
      return _peersManager!.averageUploadSpeed;
    } else {
      return 0.0;
    }
  }

  @override
  double get currentDownloadSpeed {
    if (_peersManager != null) {
      return _peersManager!.currentDownloadSpeed;
    } else {
      return 0.0;
    }
  }

  @override
  double get uploadSpeed {
    if (_peersManager != null) {
      return _peersManager!.uploadSpeed;
    } else {
      return 0.0;
    }
  }

  late String _infoHashString;

  Timer? _dhtRepeatTimer;

  Future<PeersManager> _init(Torrent model, String savePath) async {
    _lsd = LSD(model.infoHash, _peerId);
    _infoHashString = String.fromCharCodes(model.infoHashBuffer);
    _tracker ??= TorrentAnnounceTracker(this);
    _stateFile ??= await StateFile.getStateFile(savePath, model);
    _pieceManager ??= PieceManager.createPieceManager(
        BasePieceSelector(), model, _stateFile!.bitfield);
    _fileManager ??= await DownloadFileManager.createFileManager(
        model, savePath, _stateFile!, _pieceManager!.pieces);
    _peersManager ??= PeersManager(
        _peerId, _pieceManager!, _pieceManager!, _fileManager!, model);
    return _peersManager!;
  }

  @override
  void addPeer(CompactAddress address, PeerSource source,
      {PeerType? type, Socket? socket}) {
    _peersManager?.addNewPeerAddress(address, source,
        type: type, socket: socket);
  }

  void _whenTaskDownloadComplete(AllComplete event) async {
    await _peersManager
        ?.disposeAllSeeder('Download complete,disconnect seeder');
    await _tracker?.complete();
    events.emit(TaskCompleted());
  }

  void _whenFileDownloadComplete(DownloadManagerFileCompleted event) {
    events.emit(TaskFileCompleted(event.filePath));
  }

  void _processTrackerPeerEvent(AnnouncePeerEventEvent event) {
    if (event.event == null) return;
    var ps = event.event!.peers;
    if (ps.isNotEmpty) {
      for (var url in ps) {
        _processNewPeerFound(url, PeerSource.tracker);
      }
    }
  }

  void _processLSDPeerEvent(LSDNewPeer event) {
    print('There is LSD! !');
  }

  void _processNewPeerFound(CompactAddress url, PeerSource source) {
    log("Add new peer ${url.toString()} from ${source.name} to peersManager",
        name: runtimeType.toString());
    _peersManager?.addNewPeerAddress(url, source);
  }

  void _processDHTPeer(CompactAddress peer, String infoHash) {
    log("Got new peer from $peer DHT for infohash: ${Uint8List.fromList(infoHash.codeUnits).toHexString()}",
        name: runtimeType.toString());
    if (infoHash == _infoHashString) {
      _processNewPeerFound(peer, PeerSource.dht);
    }
  }

  // TODO(ivn): _hookUTP
  // ignore: unused_element
  void _hookUTP(UTPSocket socket) {
    if (socket.remoteAddress == localAddress) {
      socket.close();
      return;
    }
    if (_comingIp.length >= maxInPeers || !_comingIp.add(socket.address)) {
      socket.close();
      return;
    }
    log('incoming connect: ${socket.remoteAddress.address}:${socket.remotePort}',
        name: runtimeType.toString());
    _peersManager?.addNewPeerAddress(
        CompactAddress(socket.remoteAddress, socket.remotePort),
        PeerSource.incoming,
        type: PeerType.UTP,
        socket: socket);
  }

  void _hookInPeer(Socket socket) {
    if (socket.remoteAddress == localAddress) {
      socket.close();
      return;
    }
    if (_comingIp.length >= maxInPeers || !_comingIp.add(socket.address)) {
      socket.close();
      return;
    }
    log('incoming connect: ${socket.remoteAddress.address}:${socket.remotePort}',
        name: runtimeType.toString());
    _peersManager?.addNewPeerAddress(
        CompactAddress(socket.remoteAddress, socket.remotePort),
        PeerSource.incoming,
        type: PeerType.TCP,
        socket: socket);
  }

  @override
  void pause() {
    if (state == TaskState.paused) return;
    state = TaskState.paused;
    _peersManager?.pause();
    events.emit(TaskPaused());
  }

  @override
  TaskState state = TaskState.stopped;

  @override
  void resume() {
    if (state == TaskState.paused) {
      state = TaskState.running;
      _peersManager?.resume();
      events.emit(TaskResumed());
    }
  }

  @override
  Future start() async {
    state = TaskState.running;
    // Incoming peer:
    _serverSocket ??= await ServerSocket.bind(InternetAddress.anyIPv4, port);
    await _init(_metaInfo, _savePath);
    _serverSocketListener = _serverSocket?.listen(_hookInPeer);
    // _utpServer ??= await ServerUTPSocket.bind(
    //     InternetAddress.anyIPv4, _serverSocket?.port ?? 0);
    // _utpServer?.listen(_hookUTP);
    // print(_utpServer?.port);

    var map = {};
    map['name'] = _metaInfo.name;
    map['tcp_socket'] = _serverSocket?.port;
    map['complete_pieces'] = List.from(_stateFile!.bitfield.completedPieces);
    map['total_pieces_num'] = _stateFile!.bitfield.piecesNum;
    map['downloaded'] = _stateFile!.downloaded;
    map['uploaded'] = _stateFile!.uploaded;
    map['total_length'] = _metaInfo.length;
    // Outgoing peer:
    trackerListener = _tracker?.createListener();
    peersManagerListener = _peersManager?.createListener();
    fileManagerListener = _fileManager?.createListener();
    lsdListener = _lsd?.createListener();
    trackerListener?.on<AnnouncePeerEventEvent>(_processTrackerPeerEvent);

    peersManagerListener?.on<AllComplete>(_whenTaskDownloadComplete);
    fileManagerListener
      ?..on<DownloadManagerFileCompleted>(_whenFileDownloadComplete)
      ..on<StateFileUpdated>((event) => events.emit(StateFileUpdated()));
    lsdListener?.on<LSDNewPeer>(_processLSDPeerEvent);
    // _lsd?.port = _utpServer?.port;
    _lsd?.start();
    _dhtListener = _dht?.createListener();
    _dhtListener?.on<NewPeerEvent>(
        (event) => _processDHTPeer(event.address, event.infoHash));
    _dht?.announce(
        String.fromCharCodes(_metaInfo.infoHashBuffer), _serverSocket!.port);

    _dht?.bootstrap();

    if (_fileManager != null && _fileManager!.isAllComplete) {
      _tracker?.complete();
    } else {
      _tracker?.runTrackers(_metaInfo.announces, _metaInfo.infoHashBuffer,
          event: EVENT_STARTED);
    }
    events.emit(TaskStarted());
    return map;
  }

  @override
  Future stop([bool force = false]) async {
    await _tracker?.stop(force);
    events.emit(TaskStopped());
    await dispose();
  }

  Future dispose() async {
    events.dispose();
    _dhtRepeatTimer?.cancel();
    _dhtRepeatTimer = null;
    trackerListener?.dispose();
    fileManagerListener?.dispose();
    peersManagerListener?.dispose();
    lsdListener?.dispose();
    // This is in order, first stop the tracker, then stop listening on the server socket and all peers, finally close the file system.
    await _tracker?.dispose();
    _tracker = null;
    await _peersManager?.dispose();
    _peersManager = null;
    _serverSocketListener?.cancel();
    _serverSocketListener = null;
    await _serverSocket?.close();
    _serverSocket = null;
    await _fileManager?.close();
    _fileManager = null;
    await _dht?.stop();
    _dht = null;
    _lsd?.close();
    _lsd = null;
    _peerIds.clear();
    _comingIp.clear();
    state = TaskState.stopped;
    return;
  }

  @override
  Future<Map<String, dynamic>> getOptions(Uri uri, String infoHash) {
    var map = {
      'downloaded': _stateFile?.downloaded,
      'uploaded': _stateFile?.uploaded,
      'left': _metaInfo.length - _stateFile!.downloaded,
      'numwant': 50,
      'compact': 1,
      'peerId': _peerId,
      'port': _serverSocket?.port
    };
    return Future.value(map);
  }

  @override
  int? get downloaded => _fileManager?.downloaded;

  @override
  double get progress {
    var d = downloaded;
    if (d == null) return 0.0;
    var l = _metaInfo.length;
    return d / l;
  }

  @override
  int get allPeersNumber {
    if (_peersManager != null) {
      return _peersManager!.peersNumber;
    } else {
      return 0;
    }
  }

  @override
  void addDHTNode(Uri url) {
    _dht?.addBootstrapNode(url);
  }

  @override
  int get connectedPeersNumber {
    if (_peersManager != null) {
      return _peersManager!.connectedPeersNumber;
    } else {
      return 0;
    }
  }

  @override
  int get seederNumber {
    if (_peersManager != null) {
      return _peersManager!.seederNumber;
    } else {
      return 0;
    }
  }

  // TODO debug:
  @override
  double get utpDownloadSpeed {
    if (_peersManager == null) return 0.0;
    return _peersManager!.utpDownloadSpeed;
  }

// TODO debug:
  @override
  double get utpUploadSpeed {
    if (_peersManager == null) return 0.0;
    return _peersManager!.utpUploadSpeed;
  }

// TODO debug:
  @override
  int get utpPeerCount {
    if (_peersManager == null) return 0;
    return _peersManager!.utpPeerCount;
  }

  @override
  void startAnnounceUrl(Uri url, Uint8List infoHash) {
    _tracker?.runTracker(url, infoHash);
  }

  @override
  void requestPeersFromDHT() {
    _dht?.requestPeers(String.fromCharCodes(_metaInfo.infoHashBuffer));
  }
}
