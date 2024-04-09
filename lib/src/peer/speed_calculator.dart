import 'dart:math';

/// 5 seconds
const recordTime = 5000000;

/// Upload and download speed calculator.
mixin SpeedCalculator {
  final List<List<int>> _downloadedHistory = <List<int>>[];

  /// The average download speed within the last 5 seconds.
  double get currentDownloadSpeed {
    if (_downloadedHistory.isEmpty) return 0.0;
    var now = DateTime.now().microsecondsSinceEpoch;
    var d = 0;
    int? s;
    for (var i = 0; i < _downloadedHistory.length;) {
      var dd = _downloadedHistory[i];
      if ((now - dd[1]) > recordTime) {
        _downloadedHistory.removeAt(i);
      } else {
        d += dd[0];
        s ??= dd[1];
        s = min(dd[1], s);
        i++;
      }
    }
    if (d == 0) return 0.0;
    var passed = now - s!;
    if (passed == 0) return 0.0;
    return (d / 1024) / (passed / 1000000);
  }

  /// The average download speed from the start of the Peer connection until the current moment.
  double get averageDownloadSpeed {
    var passed = livingTime;
    if (passed == null || passed == 0) return 0.0;
    return (_downloaded / 1024) / (passed / 1000000);
  }

  /// The average upload speed from the start of the Peer connection until the current moment.
  double get averageUploadSpeed {
    var passed = livingTime;
    if (passed == null || passed == 0) return 0.0;
    return (_uploaded / 1024) / (passed / 1000000);
  }

  /// The duration from the start of the connection until the peer is destroyed.
  int? get livingTime {
    if (_startTime == null) return null;
    var e = _endTime;
    e ??= DateTime.now().microsecondsSinceEpoch;
    return e - _startTime!;
  }

  int? _startTime;

  int? _endTime;

  int _downloaded = 0;

  /// The total amount of data downloaded from the remote, in bytes.
  int get downloaded => _downloaded;

  int _uploaded = 0;

  /// The total amount of data uploaded to the remote, in bytes.
  int get uploaded => _uploaded;

  /// Update the download.
  void updateDownload(List<List<int>> requests) {
    if (requests.isEmpty) return;
    var downloaded = 0;
    for (var request in requests) {
      if (request[4] != 0) {
        continue; // Do not count the time for re-calculation.
      }
      downloaded += request[2];
    }
    _downloadedHistory.add([downloaded, DateTime.now().microsecondsSinceEpoch]);
    _downloaded += downloaded;
  }

  void updateUpload(int uploaded) {
    _uploaded += uploaded;
  }

  /// Start the speed calculation timer.
  void startSpeedCalculator() {
    _startTime = DateTime.now().microsecondsSinceEpoch;
  }

  /// Stop the speed calculation timer.
  void stopSpeedCalculator() {
    _endTime = DateTime.now().microsecondsSinceEpoch;
    _downloadedHistory.clear();
  }
}
