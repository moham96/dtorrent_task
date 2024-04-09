import 'dart:async';
import 'dart:io';

import 'package:dtorrent_parser/dtorrent_parser.dart';
import 'package:dtorrent_task/src/stream/torrent_stream.dart';
import 'package:dtorrent_task/src/task_events.dart';
import 'package:events_emitter2/events_emitter2.dart';
import 'package:path/path.dart' as path;

var scriptDir = path.dirname(Platform.script.path);
var torrentsPath =
    path.canonicalize(path.join(scriptDir, '..', '..', '..', 'torrents'));

Future<void> main(List<String> args) async {
  var torrentFile = path.join(torrentsPath, 'big-buck-bunny.torrent');
  var savePath = path.join(scriptDir, '..', 'tmp');
  var model = await Torrent.parse(torrentFile);
  // model.announces.clear();
  var task = TorrentStream(model, savePath);
  Timer? timer;
  var startTime = DateTime.now().millisecondsSinceEpoch;
  EventsListener<TaskEvent> listener = task.createListener();
  listener
    ..on<TaskCompleted>((event) {
      print(
          'Complete! spend time : ${((DateTime.now().millisecondsSinceEpoch - startTime) / 60000).toStringAsFixed(2)} minutes');
      timer?.cancel();
      task.stop();
    })
    ..on<TaskStopped>(((event) {
      print('Task Stopped');
    }));
  var map = await task.start();

  print(map);

  timer = Timer.periodic(Duration(seconds: 2), (timer) async {
    var progress = '${(task.progress * 100).toStringAsFixed(2)}%';
    var ads = ((task.averageDownloadSpeed) * 1000 / 1024).toStringAsFixed(2);
    var aps = ((task.averageUploadSpeed) * 1000 / 1024).toStringAsFixed(2);
    var ds = ((task.currentDownloadSpeed) * 1000 / 1024).toStringAsFixed(2);
    var ps = ((task.uploadSpeed) * 1000 / 1024).toStringAsFixed(2);

    var utpd = ((task.utpDownloadSpeed) * 1000 / 1024).toStringAsFixed(2);
    var utpu = ((task.utpUploadSpeed) * 1000 / 1024).toStringAsFixed(2);
    var utpc = task.utpPeerCount;

    var active = task.connectedPeersNumber;
    var seeders = task.seederNumber;
    var all = task.allPeersNumber;
    print(
        'Progress : $progress , Peers:($active/$seeders/$all)($utpc) . Download speed : ($utpd)($ads/$ds)kb/s , upload speed : ($utpu)($aps/$ps)kb/s');
  });
}
