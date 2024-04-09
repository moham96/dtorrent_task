import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:b_encode_decode/b_encode_decode.dart';
import 'package:dtorrent_common/dtorrent_common.dart';

import '../peer/peer.dart';

const pexFlagPrefersEncryption = 0x01;

const pexFlagUploadOnly = 0x02;

const pexFlagSupportsUTP = 0x04;

const pexFlagSupportsHolepunch = 0x08;

const pexFlagReachable = 0x10;

mixin PEX {
  Timer? _timer;

  final Set<CompactAddress> _lastUTPEX = <CompactAddress>{};

  void startPEX() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: 60), (timer) {
      sendUtPexPeers();
    });
  }

  Iterable<Peer> get activePeers;

  void sendUtPexPeers() {
    var dropped = <CompactAddress>[];
    var added = <CompactAddress>[];
    for (var p in activePeers) {
      if (!_lastUTPEX.remove(p.address)) {
        added.add(p.address);
      }
    }
    for (var element in _lastUTPEX) {
      dropped.add(element);
    }
    _lastUTPEX.clear();

    var data = {};
    data['added'] = [];
    for (var element in added) {
      _lastUTPEX.add(element);
      data['added'].addAll(element.toBytes());
    }
    data['dropped'] = [];
    for (var element in dropped) {
      data['dropped'].addAll(element.toBytes());
    }
    if (data['added'].isEmpty && data['dropped'].isEmpty) return;
    var message = encode(data);
    for (var peer in activePeers) {
      peer.sendExtendMessage('ut_pex', message);
    }
  }

  dynamic parsePEXDatas(dynamic source, List<int> message) {
    var datas = decode(Uint8List.fromList(message));
    _parseAdded(source, datas);
    _parseAdded(source, datas, 'added6', InternetAddressType.IPv6);
  }

  dynamic _parseAdded(dynamic source, Map datas,
      [String keyStr = 'added',
      InternetAddressType type = InternetAddressType.IPv4]) {
    var added = datas[keyStr];
    if (added != null && added is List && added.isNotEmpty) {
      if (added is! List<int>) {
        added = _convert(added);
      }
      List? ips;
      try {
        if (type == InternetAddressType.IPv4) {
          ips = CompactAddress.parseIPv4Addresses(added);
        }
        if (type == InternetAddressType.IPv6) {
          ips = CompactAddress.parseIPv6Addresses(added);
        }
      } catch (e) {
        // do nothing
      }
      var flag = datas['$keyStr.f'];
      if (flag != null && flag is List && flag.isNotEmpty) {
        if (flag is! List<int>) {
          flag = _convert(flag);
        }
        if (ips != null && ips.isNotEmpty) {
          for (var i = 0; i < ips.length; i++) {
            var f = flag[i];
            var opts = {};
            if (f & pexFlagPrefersEncryption == pexFlagPrefersEncryption) {
              opts['e'] = true;
            }
            if (f & pexFlagUploadOnly == pexFlagUploadOnly) {
              opts['uploadonly'] = true;
            }
            if (f & pexFlagSupportsUTP == pexFlagSupportsUTP) {
              opts['utp'] = true;
            }
            if (f & pexFlagSupportsHolepunch == pexFlagSupportsHolepunch) {
              opts['holepunch'] = true;
            }
            if (f & pexFlagReachable == pexFlagReachable) {
              opts['reachable'] = true;
            }
            Timer.run(() => addPEXPeer(source, ips?[i], opts));
          }
        }
      }
    }
  }

  void addPEXPeer(dynamic source, CompactAddress address, Map options);

  List<int>? _convert(List added) {
    var intList = <int>[];
    for (var i = 0; i < added.length; i++) {
      var n = added[i];
      if (n is int && n >= 0 && n < 256) {
        intList.add(n);
      } else {
        return null;
      }
    }
    return intList;
  }

  void clearPEX() {
    _timer?.cancel();
    _lastUTPEX.clear();
  }
}
