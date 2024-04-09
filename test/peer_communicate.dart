import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dtorrent_common/dtorrent_common.dart';
import 'package:dtorrent_task/dtorrent_task.dart';
import 'package:dtorrent_task/src/peer/peer_events.dart';

void main() async {
  ServerSocket? serverSocket;
  int serverPort;
  var infoBuffer = randomBytes(20);
  var piecesNum = 20;
  var bitfield = Bitfield.createEmptyBitfield(piecesNum);
  bitfield.setBit(10, true);
  var callMap = <String, bool>{
    'connect1': false,
    'handshake1': false,
    'connect2': false,
    'handshake2': false,
    'choke': false,
    'interested': false,
    'bitfield': false,
    'have': false,
    'request': false,
    'piece': false,
    'port': false,
    'have_all': false,
    'have_none': false,
    'keep_live': false,
    'cancel': false,
    'reject_request': false,
    'allow_fast': false,
    'suggest_piece': false
  };
  serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  serverPort = serverSocket.port;
  serverSocket.listen((socket) {
    print('client connected : ${socket.address}:${socket.port}');
    var peer = Peer.newTCPPeer(
        generatePeerId(),
        CompactAddress(socket.address, socket.port),
        infoBuffer,
        piecesNum,
        socket,
        PeerSource.incoming);
    var peerListener = peer.createListener();
    peerListener
      ..on<PeerConnected>((event) {
        callMap['connect1'] = true;
        event.peer.sendHandShake();
      })
      ..on<PeerHandshakeEvent>((event) {
        callMap['handshake1'] = true;
        print('receive ${event.remotePeerId} handshake');
        event.peer.sendInterested(true);
        print('send interested to ${event.remotePeerId}');
      })
      ..on<PeerBitfieldEvent>((event) {
        assert(event.bitfield!.getBit(10));
        print('receive client bitfield');
        callMap['bitfield'] = true;
      })
      ..on<PeerInterestedChanged>((event) {
        callMap['interested'] = true;
        print('receive client interested');
        event.peer.sendChoke(false);
        print('send choke false to client');
      })
      ..on<PeerChokeChanged>((event) {
        {
          callMap['choke'] = true;
          print('receive client choke change');
        }
      })
      ..on<PeerRequestEvent>((event) {
        callMap['request'] = true;
        assert(event.begin == 0);
        assert(event.length == defaultRequestLength);
        if (event.index == 1) {
          event.peer.sendRejectRequest(
              event.index, event.begin, defaultRequestLength);
        }
      })
      ..on<PeerCancelEvent>((event) {
        callMap['cancel'] = true;
        assert(event.index == 1);
        assert(event.begin == 0);
        assert(event.length == defaultRequestLength);
        print('receive client cancel');
      })
      ..on<PeerPortChanged>((event) {
        callMap['port'] = true;
        assert(event.port == 3321);
        print('receive client onPortChange');
      })
      ..on<PeerHaveEvent>((event) {
        callMap['have'] = true;
        assert(event.indices[0] == 2);
        print('receive client have');
      })
      ..on<PeerKeepAlive>((event) {
        callMap['keep_live'] = true;
      })
      ..on<PeerHaveAll>((event) {
        callMap['have_all'] = true;
        print('receive client have all');
      })
      ..on<PeerHaveNone>((event) {
        callMap['have_none'] = true;
        print('receive client have none');
      })
      ..on<PeerSuggestPiece>((event) {
        assert(event.index == 3);
        callMap['suggest_piece'] = true;
        event.peer.sendRequest(event.index, 0);
        print('receive client suggest');
      })
      ..on<PeerAllowFast>((event) {
        assert(event.index == 4);
        callMap['allow_fast'] = true;
        Timer.run(() => event.peer.sendRequest(event.index, 0));
        print('receive client allow fast');
      })
      ..on<PeerPieceEvent>((event) async {
        callMap['piece'] = true;
        assert(event.block.length == defaultRequestLength);
        assert(event.block[0] == event.index);
        assert(event.block[1] == event.begin);
        var id = String.fromCharCodes(event.block.getRange(2, 22));
        assert(id == peer.remotePeerId);
        if (event.index == 4) {
          print('Testing completed. $callMap');
          await peer.dispose(BadException('Testing completed'));
        }
      })
      ..on<PeerDisposeEvent>((event) async {
        print('come in destroyed : ${event.reason}');
        await serverSocket?.close();
        serverSocket = null;
      });

    peer.connect();
  });

  var pid = generatePeerId();
  var peer = Peer.newTCPPeer(
      pid,
      CompactAddress(InternetAddress.tryParse('127.0.0.1')!, serverPort),
      infoBuffer,
      piecesNum,
      null,
      PeerSource.manual);
  var peerListener = peer.createListener();
  peerListener
    ..on<PeerConnected>((event) {
      callMap['connect2'] = true;
      print('connect server success');
      event.peer.sendHandShake();
      // peer.dispose();
    })
    ..on<PeerHandshakeEvent>((event) {
      callMap['handshake2'] = true;
      print('receive ${event.remotePeerId} handshake');
      event.peer.sendBitfield(bitfield);
      print('send bitfield to server');
      event.peer.sendInterested(true);
      print('send interested true to server');
      event.peer.sendChoke(false);
      print('send choke false to server');
    })
    ..on<PeerChokeChanged>((event) {
      if (!event.choked) {
        event.peer.sendRequest(1, 0);
        event.peer.requestCancel(1, 0, defaultRequestLength);
        event.peer.sendRequest(1, 0);
        event.peer.sendHave(2);
        event.peer.sendKeepAlive();
        event.peer.sendPortChange(3321);
        event.peer.sendHaveAll();
        event.peer.sendHaveNone();
        event.peer.sendSuggestPiece(3);
      }
    })
    ..on<PeerRejectEvent>((event) {
      assert(event.index == 1);
      assert(event.begin == 0);
      assert(event.length == defaultRequestLength);
      callMap['reject_request'] = true;
    })
    ..on<PeerRequestEvent>((event) {
      var content = Uint8List(defaultRequestLength);
      var view = ByteData.view(content.buffer);
      view.setUint8(0, event.index);
      view.setUint8(1, event.begin);
      var id = event.peer.localPeerId;
      var idContent = utf8.encode(id);
      for (var i = 0; i < idContent.length; i++) {
        view.setUint8(i + 2, idContent[i]);
      }
      event.peer.sendPiece(event.index, event.begin, content);
      event.peer.sendChoke(true); // Testing "allow fast".
      event.peer.sendAllowFast(4);
    })
    ..on<PeerDisposeEvent>((event) async {
      print('come out destroyed : ${event.reason}');
      await serverSocket?.close();
      serverSocket = null;
      var callAll = callMap.values.fold<bool>(
          true, (previousValue, element) => (previousValue && element));
      assert(callAll);
    });
  print('connect to : ${peer.address}');
  await peer.connect();
}
