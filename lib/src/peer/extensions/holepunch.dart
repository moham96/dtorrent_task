import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dtorrent_common/dtorrent_common.dart';
import 'package:logging/logging.dart';

enum HolepunchType { rendezvous, connect, error }

var _log = Logger('HolePunchMixin');
mixin Holepunch {
  static const MESSAGE_TYPE = [
    HolepunchType.rendezvous,
    HolepunchType.connect,
    HolepunchType.error
  ];

  static const ERROR_MSG = [
    'NoSuchPeer - The target endpoint is invalid.',
    'NotConnected	The relaying peer is not connected to the target peer.',
    'NoSupport	The target peer does not support the holepunch extension.',
    'NoSelf	The target endpoint belongs to the relaying peer.'
  ];

  List<int> getRendezvousMessage(CompactAddress address) {
    List<int> message = List.empty();
    if (address.address.type == InternetAddressType.IPv4) {
      message = List<int>.filled(12, 0);
      List.copyRange(message, 2, address.toBytes());
    }
    if (address.address.type == InternetAddressType.IPv6) {
      message = List<int>.filled(24, 0);
      List.copyRange(message, 2, address.toBytes());
    }
    return message;
  }

  /// msg_type (1 byte): <type of holepunch message>
  ///
  /// addr_type (1 byte): <0x00 for ipv4, 0x01 for ipv6>
  ///
  /// addr (either 4 or 16 bytes): <big-endian ipv4 or ipv6 address, as determined by addr_type>
  ///
  /// port (2 bytes): <big-endian port number>
  ///
  /// err_code (4 bytes): <error code as a big-endian 4-byte integer; 0 in non-error messages>
  void parseHolepunchMessage(List<int> data) {
    _log.fine('Parsing holepunch message');
    var type = data[0];
    var ipType = data[1];
    var offset = 0;
    CompactAddress? ip;
    try {
      if (ipType == 0) {
        ip = CompactAddress.parseIPv4Address(data, 2);
        offset = 8;
      } else {
        ip = CompactAddress.parseIPv6Address(data, 2);
        offset = 20;
      }
    } catch (e) {
      // do nothing
    }
    if (ip == null) return;
    int err;
    if (type == 0x02) {
      var e = Uint8List(4);
      // Some clients return less than 4 errors：
      if (data.length < offset + 4) {
        var start = offset + 4 - data.length;
        List.copyRange(e, start, data, offset);
      } else {
        List.copyRange(e, 0, data, offset);
      }
      err = ByteData.view(e.buffer).getUint32(0);
      if (err >= 1000) {
        err = e[0]; // Some clients put the error code first
      }
      err--;
      var errMsg = 'Unknown error';
      if (err >= 0) {
        errMsg = ERROR_MSG[err];
      }
      Timer.run(() => holePunchError(errMsg, ip!));
      return;
    }

    if (type == 0x00) {
      Timer.run(() => holePunchRendezvous(ip!));
      return;
    }

    if (type == 0x01) {
      Timer.run(() => holePunchConnect(ip!));
      return;
    }
  }

  void holePunchError(String err, CompactAddress ip);

  void holePunchConnect(CompactAddress ip);

  void holePunchRendezvous(CompactAddress ip);

  void clearHolepunch() {
    // clean here
  }
}
