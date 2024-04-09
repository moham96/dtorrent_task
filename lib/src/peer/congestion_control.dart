import 'dart:async';
import 'dart:math';

import 'package:dtorrent_task/src/peer/peer_events.dart';
import 'package:events_emitter2/events_emitter2.dart';

import '../utils.dart';

/// 500 ms
const controlTarget = 1000000;

const maxWindow = 1048576;

const recordTime = 5000000;

/// The maximum number of requests to be increased in each round is 3.
const maxCwndIncreaseRequestsPerRTT =
    3 * 16384; // MAX_CWND_INCREASE_REQUESTS_PER_RTT

/// LEDBAT Congestion Control
///
/// Note: All time units are in microseconds
mixin CongestionControl on EventsEmittable<PeerEvent> {
  // The initial value is 10 seconds.
  double _rto = 10000000;

  double? _srtt;

  double? _rttvar;

  Timer? _timeout;

  int _allowWindowSize = defaultRequestLength;

  final List<List<dynamic>> _downloadedHistory = <List<dynamic>>[];

  /// Update the timeout.
  void updateRTO(int rtt) {
    if (rtt == 0) return;
    if (_srtt == null) {
      _srtt = rtt.toDouble();
      _rttvar = rtt / 2;
    } else {
      _rttvar = (1 - 0.25) * _rttvar! + 0.25 * (_srtt! - rtt).abs();
      _srtt = (1 - 0.125) * _srtt! + 0.125 * rtt;
    }
    _rto = _srtt! + max(100000, 4 * _rttvar!);
    // If less than 1 second, set it to 1 second.
    _rto = max(_rto, 1000000);
  }

  List<List<int>> get currentRequestBuffer;

  void timeOutErrorHappen();

  void orderResendRequest(int index, int begin, int length, int resend);

  void startRequestDataTimeout([int times = 0]) {
    _timeout?.cancel();
    var requests = currentRequestBuffer;
    if (requests.isEmpty) return;
    _timeout = Timer(Duration(microseconds: _rto.toInt()), () {
      if (requests.isEmpty) return;
      if (times + 1 >= 5) {
        timeOutErrorHappen();
        return;
      }

      var now = DateTime.now().microsecondsSinceEpoch;
      var first = requests.first;
      var timeoutR = <List<int>>[];
      while ((now - first[3]) > _rto) {
        var request = requests.removeAt(0);
        timeoutR.add(request);
        if (requests.isEmpty) break;
        first = requests.first;
      }
      for (var request in timeoutR) {
        orderResendRequest(request[0], request[1], request[2], request[4]);
      }

      times++;
      _rto *= 2;
      _allowWindowSize = defaultRequestLength;
      events.emit(RequestTimeoutEvent(timeoutR));
      startRequestDataTimeout(times);
    });
  }

  void ackRequest(List<List<int>> requests) {
    if (requests.isEmpty) return;
    var downloaded = 0;
    int? minRtt;
    for (var request in requests) {
      // Ignore the received packets after resending.
      if (request[4] != 0) continue;
      var now = DateTime.now().microsecondsSinceEpoch;
      var rtt = now - request[3];
      minRtt ??= rtt;
      minRtt = min(minRtt, rtt);
      updateRTO(rtt);
      downloaded += request[2];
    }
    if (downloaded == 0 || minRtt == null) return;
    var artt = minRtt;
    var delayFactor = (controlTarget - artt) / controlTarget;
    var windowFactor = downloaded / _allowWindowSize;
    var scaledGain = maxCwndIncreaseRequestsPerRTT * delayFactor * windowFactor;

    _allowWindowSize += scaledGain.toInt();
    _allowWindowSize = max(defaultRequestLength, _allowWindowSize);
    _allowWindowSize = min(maxWindow, _allowWindowSize);
  }

  int get currentWindow {
    var c = _allowWindowSize ~/ defaultRequestLength;
    // var cw = 2 + (currentSpeed * 500 / DEFAULT_REQUEST_LENGTH).ceil();
    // print('$cw, $c');
    return c;
  }

  void clearCC() {
    _timeout?.cancel();
    _downloadedHistory.clear();
  }
}
