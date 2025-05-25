import 'package:dtorrent_common/dtorrent_common.dart';
import 'package:dtorrent_task/src/peer/protocol/peer.dart';

import 'piece.dart';
import 'piece_provider.dart';
import 'piece_selector.dart';

///
/// Basic piece selector.
///
/// The basic strategy is:
///
/// - Choose the Piece with the highest number of available Peers.
/// - If multiple Pieces have the same number of available Peers, choose the one with the fewest Sub Pieces remaining.
class BasePieceSelector implements PieceSelector {
  final Set<int> _priorityPieces = {};

  @override
  void setPriorityPieces(Iterable<int> pieces) {
    _priorityPieces.clear();
    _priorityPieces.addAll(pieces);
  }

  @override
  Piece? selectPiece(Peer peer, PieceProvider provider, [bool random = false, Set<int>? suggestPieces]) {
    // Prioritize downloading Suggest Pieces.
    if (suggestPieces != null && suggestPieces.isNotEmpty) {
      for (var i = 0; i < suggestPieces.length; i++) {
        var p = provider[suggestPieces.elementAt(i)];
        if (p != null && !p.isCompleted && p.haveAvailableSubPiece()) {
          return p;
        }
      }
    }
    // Check if the current downloading piece can be used by this peer.
    var availablePiece = <int>[];

    var candidatePieces = peer.remoteCompletePieces;
    for (var i = 0; i < provider.downloadingPieces.length; i++) {
      var p = provider.pieces[provider.downloadingPieces.elementAt(i)];
      if (p == null) continue;
      if (p.containsAvailablePeer(peer) && p.haveAvailableSubPiece()) {
        availablePiece.add(p.index);
      }
    }

    // If it is possible to download a piece that is currently being downloaded,
    // prioritize downloading that piece (following the principle of multiple
    // peers downloading the same piece to complete it as soon as possible).
    if (availablePiece.isNotEmpty) {
      candidatePieces = availablePiece;
    }
    // random = true;
    var maxList = <Piece>[];
    Piece? a;
    int? startIndex;
    for (var i = 0; i < candidatePieces.length; i++) {
      var p = provider[candidatePieces[i]];
      if (p != null && !p.isCompleted && p.haveAvailableSubPiece() && p.containsAvailablePeer(peer)) {
        a = p;
        startIndex = i;
        break;
      }
    }
    if (startIndex == null) return null;
    maxList.add(a!);
    for (var i = startIndex; i < candidatePieces.length; i++) {
      var p = provider[candidatePieces[i]];
      if (p == null || !p.haveAvailableSubPiece() || !p.containsAvailablePeer(peer)) {
        continue;
      }
      // Select rare pieces
      if (a!.availablePeersCount > p.availablePeersCount) {
        if (!random) return p;
        maxList.clear();
        a = p;
        maxList.add(a);
      } else {
        if (a.availablePeersCount == p.availablePeersCount) {
          // If multiple Pieces have the same number of available downloading Peers, prioritize the one with the fewest remaining Sub Pieces.
          if (p.availableSubPieceCount < a.availableSubPieceCount) {
            if (!random) return p;
            maxList.clear();
            a = p;
            maxList.add(a);
          } else {
            if (p.availableSubPieceCount == a.availableSubPieceCount) {
              if (!random) return p;
              maxList.add(p);
              a = p;
            }
          }
        }
      }
    }
    if (random) {
      return maxList[randomInt(maxList.length)];
    }
    return a;
  }
}
