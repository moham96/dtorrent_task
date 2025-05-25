import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:b_encode_decode/b_encode_decode.dart';
import 'package:dtorrent_common/dtorrent_common.dart';

import '../protocol/peer.dart';

const pex_flag_prefers_encryption = 0x01;

const pex_flag_upload_only = 0x02;

const pex_flag_supports_uTP = 0x04;

const pex_flag_supports_holepunch = 0x08;

const pex_flag_reachable = 0x10;

mixin PEX {
  Timer? _timer;

  final Set<CompactAddress> _lastUTPEX = <CompactAddress>{};

  void startPEX() {
    _timer?.cancel();
    //era 60 segundos
    _timer = Timer.periodic(Duration(seconds: 5), (timer) {
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

    final data = <String, List<int>>{
      'added': [],
      'dropped': [],
    };
    data['added'] = [];
    for (var element in added) {
      _lastUTPEX.add(element);
      data['added']!.addAll(element.toBytes());
    }
    data['dropped'] = [];
    for (var element in dropped) {
      data['dropped']!.addAll(element.toBytes());
    }
    if (data['added']!.isEmpty && data['dropped']!.isEmpty) return;
    var message = encode(data);
    for (var peer in activePeers) {
      peer.sendExtendMessage('ut_pex', message);
    }
  }

  void parsePEXDatas(Peer source, List<int> message) {
    var datas = decode(Uint8List.fromList(message));
    _parseAdded(source, datas);
    _parseAdded(source, datas, 'added6', InternetAddressType.IPv6);
  }

  dynamic _parseAdded(dynamic source, Map datas, [String keyStr = 'added', InternetAddressType type = InternetAddressType.IPv4]) {
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
      } catch (e, st) {
        print('PEX parse error: $e\n$st');
      }
      var flag = datas['$keyStr.f'];
      if (flag != null && flag is List && flag.isNotEmpty) {
        if (flag is! List<int>) {
          flag = _convert(flag);
        }
        if (ips != null && ips.isNotEmpty) {
          for (var i = 0; i < ips.length; i++) {
            if (i > flag.length - 1) {
              // some messages appear to arrive malformed,
              // where the flags count != ips count
              continue;
            }
            var f = flag[i];
            var opts = <String, dynamic>{};
            if (f & pex_flag_prefers_encryption == pex_flag_prefers_encryption) {
              opts['e'] = true;
            }
            if (f & pex_flag_upload_only == pex_flag_upload_only) {
              opts['uploadonly'] = true;
            }
            if (f & pex_flag_supports_uTP == pex_flag_supports_uTP) {
              opts['utp'] = true;
            }
            if (f & pex_flag_supports_holepunch == pex_flag_supports_holepunch) {
              opts['holepunch'] = true;
            }
            if (f & pex_flag_reachable == pex_flag_reachable) {
              opts['reachable'] = true;
            }
            addPEXPeer(source, ips[i], opts);
          }
        }
      }
    }
  }

  void addPEXPeer(Peer source, CompactAddress address, Map<String, dynamic> options);

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
