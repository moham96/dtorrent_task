import 'dart:io';
import 'dart:typed_data';

import 'package:dtorrent_common/dtorrent_common.dart';
import 'package:dtorrent_parser/dtorrent_parser.dart';
import 'package:dtorrent_task/src/metadata/metadata_downloader.dart';
import 'package:dtorrent_task/src/metadata/metadata_downloader_events.dart';
import 'package:dtorrent_task/src/peer/protocol/peer.dart';
import 'package:dtorrent_task/src/task.dart';
import 'package:dtorrent_task/src/task_events.dart';
import 'package:dtorrent_task/src/utils.dart' show hexString2Buffer;
import 'package:dtorrent_tracker/dtorrent_tracker.dart';
import 'package:events_emitter2/events_emitter2.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

var scriptDir = path.dirname(Platform.script.path);

void main(List<String> args) async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    print(
        '[${record.loggerName}] ${record.level.name}: ${record.time}: ${record.message}');
  });
  var infohashString = 'dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c';
  var metadata = MetadataDownloader(infohashString);
  var metadataListener = metadata.createListener();
  // Metadata download contains a DHT , it will search the peer via DHT,
  // but it's too slow , sometimes DHT can not find any peers
  metadata.startDownload();
  // so for this example , I use the public trackers to help MetaData download to search Peer nodes:
  var tracker = TorrentAnnounceTracker(metadata);
  var trackerListener = tracker.createListener();

  // When metadata contents download complete , it will send this event and stop itself:
  metadataListener
    ..on<MetaDataDownloadProgress>(
        (event) => print('MetaDataDownload progress: ${event.progress}'))
    ..on<MetaDataDownloadComplete>((event) async {
      tracker.stop(true);
      var torrentModel =
          await Torrent.parseFromBytes(Uint8List.fromList(event.data));
      print('complete , info : ${torrentModel.name}');
      var startTime = DateTime.now().millisecondsSinceEpoch;
      var task =
          TorrentTask.newTask(torrentModel, path.join(scriptDir, '..', 'tmp'));
      EventsListener<TaskEvent> listener = task.createListener();
      listener
        ..on<TaskCompleted>((event) {
          print(
              'Complete! spend time : ${((DateTime.now().millisecondsSinceEpoch - startTime) / 60000).toStringAsFixed(2)} minutes');

          task.stop();
        })
        ..on<TaskStopped>(((event) {
          print('Task Stopped');
        }))
        ..on<StateFileUpdated>((event) {
          var progress = '${(task.progress * 100).toStringAsFixed(2)}%';
          var ads =
              ((task.averageDownloadSpeed) * 1000 / 1024).toStringAsFixed(2);
          var aps =
              ((task.averageUploadSpeed) * 1000 / 1024).toStringAsFixed(2);
          var ds =
              ((task.currentDownloadSpeed) * 1000 / 1024).toStringAsFixed(2);
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
      await task.start();
    });

  var infoHashBuffer = Uint8List.fromList(hexString2Buffer(infohashString)!);

  trackerListener.on<AnnouncePeerEventEvent>((event) {
    if (event.event == null) return;
    var peers = event.event!.peers;
    for (var element in peers) {
      metadata.addNewPeerAddress(element, PeerSource.tracker);
    }
  });
  findPublicTrackers().listen((announceUrls) {
    for (var element in announceUrls) {
      tracker.runTracker(element, infoHashBuffer);
    }
  });
}
