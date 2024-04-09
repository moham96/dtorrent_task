library dtorrent_task;

import 'dart:io';

export 'src/torrent_task_base.dart';
export 'src/file/file_base.dart';
export 'src/piece/piece_base.dart';
export 'src/peer/peer_base.dart';
export 'src/stream/stream.dart';
export 'src/stream/stream_events.dart';
export 'src/task_events.dart';

/// Peer ID prefix
const prefixID = '-DT0201-';

/// Current version number
Future<String?> getTorrentTaskVersion() async {
  var file = File('pubspec.yaml');
  if (await file.exists()) {
    var lines = await file.readAsLines();
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var strings = line.split(':');
      if (strings.length == 2) {
        var key = strings[0];
        var value = strings[1];
        if (key == 'version') return value;
      }
    }
  }
  return null;
}
