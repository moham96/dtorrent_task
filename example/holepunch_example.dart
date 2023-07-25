import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ipify/dart_ipify.dart';
import 'package:dartorrent_common/dartorrent_common.dart';
import 'package:dartorrent_common/src/dartorrent_common_base.dart';
import 'package:dht_dart/dht_dart.dart';
import 'package:torrent_model/torrent_model.dart';
import 'package:torrent_task/src/lsd/lsd.dart';
import 'package:torrent_task/src/peer/holepunch.dart';
import 'package:torrent_task/torrent_task.dart';
import 'package:torrent_tracker/torrent_tracker.dart';

class HolePunchTest with Holepunch implements AnnounceOptionsProvider {
  static InternetAddress LOCAL_ADDRESS =
      InternetAddress.fromRawAddress(Uint8List.fromList([127, 0, 0, 1]));
  final List<InternetAddress> IGNORE_IPS = [
    InternetAddress.tryParse('0.0.0.0')!,
    InternetAddress.tryParse('127.0.0.1')!
  ];
  final Set<InternetAddress> _incomingAddress = {};
  final Set<CompactAddress> _peersAddress = {};
  final Set<Peer> _activePeers = {};
  final Set<InternetAddress> _cominIp = {};
  String localPeerId;
  Torrent metaInfo;
  ServerSocket? _serverSocket;
  InternetAddress? localExternalIP;
  LSD? _lsd;
  DHT? _dht = DHT();
  TorrentAnnounceTracker? _tracker;
  HolePunchTest({required this.localPeerId, required this.metaInfo});

  Future<void> start() async {
    localExternalIP ??= InternetAddress.tryParse(await Ipify.ipv4());
    _serverSocket ??= await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _lsd = LSD(metaInfo.infoHash, localPeerId);
    _tracker ??= TorrentAnnounceTracker(this);
    _serverSocket?.listen(_hookInPeer);
    _tracker?.onPeerEvent(_processTrackerPeerEvent);

    _lsd?.onLSDPeer(_processLSDPeerEvent);
    _lsd?.port = _serverSocket?.port;
    _lsd?.start();

    _dht?.announce(
        String.fromCharCodes(metaInfo.infoHashBuffer), _serverSocket!.port);
    _dht?.onNewPeer(_processDHTPeer);
    // ignore: unawaited_futures
    _dht?.bootstrap();

    _tracker?.runTrackers(metaInfo.announces, metaInfo.infoHashBuffer,
        event: EVENT_STARTED);
  }

  void _processTrackerPeerEvent(Tracker source, PeerEvent? event) {
    if (event == null) return;
    var ps = event.peers;
    if (ps.isNotEmpty) {
      for (var url in ps) {
        _processNewPeerFound(url, PeerSource.tracker);
      }
    }
  }

  void startAnnounceUrl(Uri url, Uint8List infoHash) {
    _tracker?.runTracker(url, infoHash);
  }

  void _processLSDPeerEvent(CompactAddress address, String infoHash) {
    print('There is LSD! !');
  }

  void _processNewPeerFound(CompactAddress url, PeerSource source) {
    log("Processing new peer ${url.toString()} from $source",
        name: runtimeType.toString());
    addNewPeerAddress(url, source);
  }

  void _processDHTPeer(CompactAddress peer, String infoHash) {
    log("Got new peer from $peer DHT for infohash: ${Uint8List.fromList(infoHash.codeUnits).toHexString()}",
        name: runtimeType.toString());
    if (infoHash == metaInfo.infoHash) {
      _processNewPeerFound(peer, PeerSource.dht);
    }
  }

  void _hookInPeer(Socket socket) {
    if (socket.remoteAddress == LOCAL_ADDRESS) {
      socket.close();
      return;
    }
    if (_cominIp.length >= MAX_IN_PEERS || !_cominIp.add(socket.address)) {
      socket.close();
      return;
    }
    log('incoming connect: ${socket.remoteAddress.address}:${socket.remotePort}',
        name: runtimeType.toString());
    addNewPeerAddress(CompactAddress(socket.address, socket.port),
        PeerSource.incoming, PeerType.TCP, socket);
  }

  void addNewPeerAddress(CompactAddress? address, PeerSource source,
      [PeerType type = PeerType.TCP, dynamic socket]) {
    if (address == null) return;
    if (address.address == localExternalIP) return;
    if (socket != null) {
      // Indicates that it is an actively connected peer, and currently, only one IP address is allowed to connect at a time.
      if (!_incomingAddress.add(address.address)) {
        return;
      }
    }
    if (_peersAddress.add(address)) {
      log("Adding new peer ${address.toString()} from $source to peersManager",
          name: runtimeType.toString());
      Peer? peer;
      if (type == PeerType.TCP) {
        peer = Peer.newTCPPeer(localPeerId, address, metaInfo.infoHashBuffer,
            metaInfo.pieces.length, socket, source);
      }
      if (type == PeerType.UTP) {
        peer = Peer.newUTPPeer(localPeerId, address, metaInfo.infoHashBuffer,
            metaInfo.pieces.length, socket, source);
      }
      if (peer != null) _hookPeer(peer);
    }
  }

  void _hookPeer(Peer peer) {
    if (peer.address.address == localExternalIP) return;
    peer.onDispose(
        (dynamic source, [dynamic reason]) => log('peer disposed $reason'));
    peer.onBitfield(
        (dynamic source, Bitfield bitfield) => log('peer bitfield'));
    peer.onHaveAll((dynamic source) => log('peer haveall'));
    peer.onHaveNone((dynamic source, [dynamic reason]) => log('peer havenone'));
    peer.onHandShake((dynamic source, String peerid, dynamic data) =>
        log('peer handshake $peerid'));
    peer.onChokeChange(
        (dynamic source, [dynamic reason]) => log('peer chokechanged'));
    peer.onInterestedChange(
        (dynamic source, [dynamic reason]) => log('peer interestchenged'));
    peer.onConnect(_peerConnected);
    peer.onHave((dynamic source, [dynamic reason]) => log('peer onhave'));
    peer.onPiece((dynamic source, int index, int begin, List<int> block) =>
        log('peer onpiece'));
    peer.onRequest((dynamic source, int index, int begin, int length) =>
        log('peer request'));
    peer.onRequestTimeout(
        (dynamic source, [dynamic reason]) => log('peer requesttimerout'));
    peer.onSuggestPiece(
        (dynamic source, [dynamic reason]) => log('peer suggestpiece'));
    peer.onRejectRequest((dynamic source, int index, int begin, int length) =>
        log('peer rejectrequest'));
    peer.onAllowFast(
        (dynamic source, [dynamic reason]) => log('peer allowfast'));
    peer.onExtendedEvent(_processExtendedMessage);
    _registerExtended(peer);
    log('connecting to peer');
    peer.connect();
  }

  void _registerExtended(Peer peer) {
    log('registering extensions for peer ${peer.address}',
        name: runtimeType.toString());
    peer.registerExtened('ut_pex');
    peer.registerExtened('ut_holepunch');
  }

  void _peerConnected(dynamic source) {
    var peer = source as Peer;
    _activePeers.add(peer);
    peer.sendHandShake();
  }

  void _processExtendedMessage(dynamic source, String name, dynamic data) {
    log('Processing Extended Message $name from $source',
        name: runtimeType.toString());
    if (name == 'ut_holepunch') {
      parseHolepuchMessage(data, source);
    }

    if (name == 'handshake') {
      if (localExternalIP != null &&
          data['yourip'] != null &&
          (data['yourip'].length == 4 || data['yourip'].length == 16)) {
        InternetAddress myip;
        try {
          myip = InternetAddress.fromRawAddress(data['yourip']);
        } catch (e) {
          return;
        }
        if (IGNORE_IPS.contains(myip)) return;
        localExternalIP = InternetAddress.fromRawAddress(data['yourip']);
      }
    }
  }

  @override
  void holePunchConnect(CompactAddress targetIp) {
    log("holePunch connect $targetIp");
    // addNewPeerAddress(ip, PeerType.UTP);
  }

  @override
  void holePunchError(String err, CompactAddress ip) {
    log('holepunch error - $err');
  }

  @override
  void holePunchRendezvous(CompactAddress targetIp, Peer initiatingPeer) {
    // TODO: implement holePunchRendezvous
    log('Received holePunch Rendezvous from $targetIp');
  }

  @override
  Future<Map<String, dynamic>> getOptions(Uri uri, String infoHash) {
    var map = {
      'downloaded': 0,
      'uploaded': 0,
      'left': 0,
      'numwant': 50,
      'compact': 1,
      'peerId': localPeerId,
      'port': _serverSocket?.port
    };
    return Future.value(map);
  }
}

Future<Stream?> connectRemote(InternetAddress address, int port) async {
  try {
    var socket =
        await Socket.connect(address, port, timeout: Duration(seconds: 30));
    return socket;
  } on Exception catch (e) {
    throw TCPConnectException(e);
  }
}

Future<void> main(List<String> args) async {
  var torrentFile = 'example${Platform.pathSeparator}test.torrent';
  var model = await Torrent.parse(torrentFile);

  var peerId = generatePeerId();
  var test = HolePunchTest(localPeerId: peerId, metaInfo: model);
  test.start();
  test.startAnnounceUrl(
      Uri.parse('http://66.29.147.233:9000/announce'), model.infoHashBuffer);
  findPublicTrackers().listen((alist) {
    for (var element in alist) {
      test.startAnnounceUrl(element, model.infoHashBuffer);
    }
  });

  Timer.periodic(Duration(seconds: 2), (timer) {
    print(test._serverSocket?.port);
  });
}
