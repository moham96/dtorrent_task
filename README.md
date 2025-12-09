## About
Dart library for implementing BitTorrent client.

[![codecov](https://codecov.io/gh/moham96/dtorrent_task/branch/main/graph/badge.svg)](https://codecov.io/gh/moham96/dtorrent_task) 

Whole Dart Torrent client contains serival parts :
- [Bencode](https://pub.dev/packages/b_encode_decode) 
- [Tracker](https://pub.dev/packages/dtorrent_tracker)
- [DHT](https://pub.dev/packages/bittorrent_dht)
- [Torrent model](https://pub.dev/packages/dtorrent_parser)
- [Common library](https://pub.dev/packages/dtorrent_common)
- [UTP](https://pub.dev/packages/utp_protocol)

This package implements regular BitTorrent Protocol and manage above packages to work together for downloading.

## BEP Support:
- [BEP 0003 The BitTorrent Protocol Specification]
- [BEP 0005 DHT Protocal]
- [BEP 0006 Fast Extension]
- [BEP 0010	Extension Protocol]
- [BEP 0011	Peer Exchange (PEX)]
- [BEP 0014 Local Service Discovery]
- [BEP 0015 UDP Tracker Protocal]
- [BEP 0029 uTorrent transport protocol]
- [BEP 0055 Holepunch extension]

Developing:
- [BEP 0009	Extension for Peers to Send Metadata Files]

Other support will come soon.

## How to use

This package need to dependency [`dtorrent_parser`](https://pub.dev/packages/dtorrent_parser):
```
dependencies:
  dtorrent_parser : ^1.0.4
  dtorrent_task : '>= 0.2.1 < 2.0.0'
```

First , create a `Torrent` model via .torrent file:

```dart
  var model = await Torrent.parse('some.torrent');
```

Second, create a `Torrent Task` and start it:
```dart
  var task = TorrentTask.newTask(model,'savepath');
  task.start();
```

User can add some listener to monitor `TorrentTask` running:
```dart
  task.onTaskComplete(() => .....);
  task.onFileComplete((String filePath) => .....);
```

and there is some method to control the `TorrentTask`:

```dart
   // Stop task:
   task.stop();
   // Pause task:
   task.pause();
   // Resume task:
   task.resume();
```

## Testing

Run tests:
```bash
dart test
```

Run tests with coverage:
```bash
dart test --coverage=coverage
dart run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info --packages=.dart_tool/package_config.json --report-on=lib
```

Or use the provided script:
```bash
dart tool/coverage.dart
```

The coverage report will be generated at `coverage/lcov.info` and can be viewed with tools like `genhtml` or uploaded to services like Codecov.

Coverage is automatically uploaded to [Codecov](https://codecov.io) on every push and pull request via GitHub Actions.
