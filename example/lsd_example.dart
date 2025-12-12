import 'dart:io';

import 'package:dtorrent_parser/dtorrent_parser.dart';
import 'package:dtorrent_task/src/lsd/lsd.dart';
import 'package:dtorrent_task/dtorrent_task.dart';
import 'package:path/path.dart' as path;

var scriptDir = path.dirname(Platform.script.path);
var torrentsPath =
    path.canonicalize(path.join(scriptDir, '..', '..', '..', 'torrents'));

void main(List<String> args) async {
  print(await getTorrentTaskVersion());
  var torrentFile = path.join(torrentsPath, 'big-buck-bunny.torrent');
  var model = await Torrent.parseFromFile(torrentFile);
  var infoHash = model.infoHash;
  var lsd = LSD();
  lsd.registerInfoHash(infoHash, 'daa231dfa', 61111);
  lsd.start();
}
