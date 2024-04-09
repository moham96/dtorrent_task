// ignore_for_file: constant_identifier_names

import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';
import 'package:dtorrent_parser/dtorrent_parser.dart';
import '../peer/bitfield.dart';

const BITFIELD_TYPE = 'bitfield';
const DOWNLOADED_TYPE = 'downloaded';
const UPLOADED_TYPE = 'uploaded';

///
/// Download state save file
///
/// Document Content：`<bitfield><download>`,where`<download>`is a 64-bit integer，
/// file name：`<infohash>.bt.state`
class StateFile {
  late Bitfield _bitfield;

  bool _closed = false;

  int _uploaded = 0;

  final Torrent metainfo;

  StateFile(this.metainfo);

  RandomAccessFile? _access;

  File? _bitfieldFile;

  StreamSubscription? _streamSubscription;

  StreamController? _streamController;

  bool get isClosed => _closed;

  static Future<StateFile> getStateFile(
      String directoryPath, Torrent metainfo) async {
    var stateFile = StateFile(metainfo);
    await stateFile.init(directoryPath, metainfo);
    return stateFile;
  }

  Bitfield get bitfield => _bitfield;

  int get downloaded {
    var downloaded = bitfield.completedPieces.length * metainfo.pieceLength;
    if (bitfield.completedPieces.contains(bitfield.piecesNum - 1)) {
      downloaded -= metainfo.pieceLength - metainfo.lastPieceLength;
    }
    return downloaded;
  }

  int get uploaded => _uploaded;

  Future<File> init(String directoryPath, Torrent metainfo) async {
    var lastChar = directoryPath.substring(directoryPath.length - 1);
    if (lastChar != Platform.pathSeparator) {
      directoryPath = directoryPath + Platform.pathSeparator;
    }

    _bitfieldFile = File('$directoryPath${metainfo.infoHash}.bt.state');
    var exists = await _bitfieldFile?.exists();
    if (exists != null && !exists) {
      _bitfieldFile = await _bitfieldFile?.create(recursive: true);
      _bitfield = Bitfield.createEmptyBitfield(metainfo.pieces.length);
      _uploaded = 0;
      var acc = await _bitfieldFile?.open(mode: FileMode.writeOnly);
      acc = await acc?.truncate(_bitfield.length + 8);
      await acc?.close();
    } else {
      var bytes = await _bitfieldFile!.readAsBytes();
      var piecesNum = metainfo.pieces.length;
      var bitfieldBufferLength = piecesNum ~/ 8;
      if (bitfieldBufferLength * 8 != piecesNum) bitfieldBufferLength++;
      _bitfield = Bitfield.copyFrom(piecesNum, bytes, 0, bitfieldBufferLength);
      var view = ByteData.view(bytes.buffer);
      _uploaded = view.getUint64(_bitfield.length);
    }

    return _bitfieldFile!;
  }

  Future<bool> update(int index, {bool have = true, int uploaded = 0}) async {
    _access = await getAccess();
    var completer = Completer<bool>();
    _streamController?.add({
      'type': 'single',
      'index': index,
      'uploaded': uploaded,
      'have': have,
      'completer': completer
    });
    return completer.future;
  }

  Future<bool> updateAll(List<int> indices,
      {List<bool>? have, int uploaded = 0}) async {
    _access = await getAccess();
    var completer = Completer<bool>();
    _streamController?.add({
      'type': 'all',
      'indices': indices,
      'uploaded': uploaded,
      'have': have,
      'completer': completer
    });
    return completer.future;
  }

  Future<void> _update(event) async {
    int index = event['index'];
    int uploaded = event['uploaded'];
    bool have = event['have'];
    Completer c = event['completer'];
    if (index != -1) {
      if (_bitfield.getBit(index) == have && _uploaded == uploaded) {
        c.complete(false);
        return;
      }
      _bitfield.setBit(index, have);
    } else {
      if (_uploaded == uploaded) return;
    }
    _uploaded = uploaded;
    try {
      var access = await getAccess();
      if (index != -1) {
        var i = index ~/ 8;
        await access?.setPosition(i);
        await access?.writeByte(_bitfield.buffer[i]);
      }
      await access?.setPosition(_bitfield.buffer.length);
      var data = Uint8List(8);
      var d = ByteData.view(data.buffer);
      d.setUint64(0, uploaded);
      access = await access?.writeFrom(data);
      await access?.flush();
      c.complete(true);
    } catch (e) {
      log('Update bitfield piece:[$index],uploaded:$uploaded error :',
          error: e, name: runtimeType.toString());
      c.complete(false);
    }
    return;
  }

  Future<bool> updateBitfield(int index, [bool have = true]) async {
    if (_bitfield.getBit(index) == have) return false;
    return update(index, have: have, uploaded: _uploaded);
  }

  // Future<bool> updateBitfields(List<int> indices, [List<bool> haves]) async {
  //   return updateAll(indices, have: haves, uploaded: _uploaded);
  // }

  Future<bool> updateUploaded(int uploaded) async {
    if (_uploaded == uploaded) return false;
    return update(-1, uploaded: uploaded);
  }

  void _processRequest(event) async {
    _streamSubscription?.pause();
    // if (event['type'] == 'all') {
    //   await _updateAll(event);
    // }
    if (event['type'] == 'single') {
      await _update(event);
    }
    _streamSubscription?.resume();
  }

  Future<RandomAccessFile?> getAccess() async {
    if (_access == null) {
      _access = await _bitfieldFile?.open(mode: FileMode.writeOnlyAppend);
      _streamController = StreamController();
      _streamSubscription = _streamController?.stream
          .listen(_processRequest, onError: (e) => print(e));
    }
    return _access;
  }

  Future<void> close() async {
    if (isClosed) return;
    _closed = true;
    try {
      await _streamSubscription?.cancel();
      await _streamController?.close();
      await _access?.flush();
      await _access?.close();
    } catch (e) {
      log('Error while closing the status file: ',
          error: e, name: runtimeType.toString());
    } finally {
      _access = null;
      _streamSubscription = null;
      _streamController = null;
    }
  }

  Future<FileSystemEntity?> delete() async {
    await close();
    var r = _bitfieldFile?.delete();
    _bitfieldFile = null;
    return r;
  }
}
