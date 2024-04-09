import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:dtorrent_common/dtorrent_common.dart';
import 'package:dtorrent_parser/dtorrent_parser.dart';
import 'package:dtorrent_task/src/task.dart';
import 'package:dtorrent_task/src/task_events.dart';
import 'package:events_emitter2/events_emitter2.dart';
import 'package:path/path.dart' as path;

var scriptDir = path.dirname(Platform.script.path);
var torrentsPath =
    path.canonicalize(path.join(scriptDir, '..', '..', '..', 'torrents'));

void main() async {
  try {
    var torrentFile = path.join(torrentsPath, 'big-buck-bunny.torrent');
    var savePath = path.join(scriptDir, '..', 'tmp');
    var model = await Torrent.parse(torrentFile);
    var task = TorrentTask.newTask(model, savePath);
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
    findPublicTrackers().listen((announceUrls) {
      for (var element in announceUrls) {
        task.startAnnounceUrl(element, model.infoHashBuffer);
      }
    });
    log('Adding dht nodes');
    for (var element in model.nodes) {
      log('dht node $element');
      task.addDHTNode(element);
    }
    print(map);

    timer = Timer.periodic(Duration(seconds: 2), (timer) async {
      var progress = '${(task.progress * 100).toStringAsFixed(2)}%';
      var ads = ((task.averageDownloadSpeed) * 1000 / 1024).toStringAsFixed(2);
      var aps = ((task.averageUploadSpeed) * 1000 / 1024).toStringAsFixed(2);
      var ds = ((task.currentDownloadSpeed) * 1000 / 1024).toStringAsFixed(2);
      var ps = ((task.uploadSpeed) * 1000 / 1024).toStringAsFixed(2);

      var utpDownloadSpeed =
          ((task.utpDownloadSpeed) * 1000 / 1024).toStringAsFixed(2);
      var utpUploadSpeed =
          ((task.utpUploadSpeed) * 1000 / 1024).toStringAsFixed(2);
      var utpPeerCount = task.utpPeerCount;

      var active = task.connectedPeersNumber;
      var seeders = task.seederNumber;
      var all = task.allPeersNumber;
      print(
          'Progress : $progress , Peers:($active/$seeders/$all)($utpPeerCount) . Download speed : ($utpDownloadSpeed)($ads/$ds)kb/s , upload speed : ($utpUploadSpeed)($aps/$ps)kb/s');
    });
  } catch (e) {
    print(e);
  }
}
