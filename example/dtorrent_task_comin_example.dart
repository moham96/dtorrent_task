import 'dart:async';
import 'dart:io';

import 'package:dtorrent_common/dtorrent_common.dart';
import 'package:dtorrent_parser/dtorrent_parser.dart';
import 'package:dtorrent_task/src/peer/peer.dart';
import 'package:dtorrent_task/src/task.dart';
import 'package:dtorrent_task/src/task_events.dart';
import 'package:events_emitter2/events_emitter2.dart';
import 'package:path/path.dart' as path;

var scriptDir = path.dirname(Platform.script.path);
var torrentsPath =
    path.canonicalize(path.join(scriptDir, '..', '..', '..', 'torrents'));

/// This example is for connect local
Future<void> main() async {
  var model =
      await Torrent.parse(path.join(torrentsPath, 'big-buck-bunny.torrent'));
  // No peers retrieval
  model.announces.clear();
  var task = TorrentTask.newTask(model, path.join(scriptDir, '..', 'tmp'));
  Timer? timer;
  EventsListener<TaskEvent> listener = task.createListener();
  listener
    ..on<TaskCompleted>((event) {
      print('Complete!');
      timer?.cancel();
      task.stop();
    })
    ..on<TaskStopped>(((event) {
      print('Task Stopped');
    }))
    ..on<TaskFileCompleted>(
      (event) {
        print('${event.filePath} downloaded complete');
      },
    );

  await task.start();

  timer = Timer.periodic(Duration(seconds: 2), (timer) {
    try {
      print(
          'Downloaded: ${task.downloaded ?? 0 / (1024 * 1024)} mb , ${((task.downloaded ?? 0 / model.length) * 100).toStringAsFixed(2)}%');
    } finally {}
  });

  // timer = Timer.periodic(Duration(seconds: 10), (timer) async {
  //   print(
  //       'download speed : ${(await task.downloadSpeed) * 1000 / 1024} , upload speed : ${task.uploadSpeed * 1000 / 1024}');
  // });
  // timer1 = Timer.periodic(Duration(seconds: randomInt(21)), (timer) async {
  //   task.pause();
  //   await Future.delayed(Duration(seconds: randomInt(121)));
  //   task.resume();
  // });

  // Timer(Duration(seconds: 20), () async {
  //   task.pause();
  //   await Future.delayed(Duration(seconds: 120));
  //   task.resume();
  // });
  // download from yourself
  task.addPeer(CompactAddress(InternetAddress.tryParse('192.168.0.24')!, 57331),
      PeerSource.manual);
}
