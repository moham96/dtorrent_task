import 'dart:convert';

import 'package:dtorrent_common/dtorrent_common.dart';
import 'package:dtorrent_task/dtorrent_task.dart';

/// Generates a unique peer ID for BitTorrent protocol.
///
/// The peer ID consists of a prefix (default: ID_PREFIX) followed by
/// 9 random bytes encoded in base64, resulting in a 20-byte peer ID.
///
/// [prefix] The prefix to use (defaults to ID_PREFIX).
/// Returns a 20-character string representing the peer ID.
String generatePeerId([String prefix = ID_PREFIX]) {
  var r = randomBytes(9);
  var base64Str = base64Encode(r);
  var id = prefix + base64Str;
  return id;
}

/// Converts a hexadecimal string to a list of bytes.
///
/// [hexStr] The hexadecimal string to convert (must have even length).
/// Returns a list of bytes, or null if the string is invalid.
List<int>? hexString2Buffer(String hexStr) {
  if (hexStr.isEmpty || hexStr.length.remainder(2) != 0) {
    return null;
  }
  var size = hexStr.length ~/ 2;
  var re = <int>[];
  for (var i = 0; i < size; i++) {
    var s = hexStr.substring(i * 2, i * 2 + 2);
    try {
      var byte = int.parse(s, radix: 16);
      re.add(byte);
    } catch (e) {
      // Invalid hex character
      return null;
    }
  }
  return re;
}

/// pow(2, 14)
///
/// download piece max size
const DEFAULT_REQUEST_LENGTH = 16384;

/// pow(2,17)
///
/// Remote is request piece length large or eqaul this length
/// , it must close the connection
const MAX_REQUEST_LENGTH = 131072;
