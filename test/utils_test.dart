import 'package:dtorrent_task/dtorrent_task.dart';
import 'package:test/test.dart';

void main() {
  group('generatePeerId', () {
    test('generates peer ID with default prefix', () {
      final peerId = generatePeerId();
      expect(peerId, startsWith(ID_PREFIX));
      expect(peerId.length, greaterThan(ID_PREFIX.length));
    });

    test('generates peer ID with custom prefix', () {
      const customPrefix = '-TEST-';
      final peerId = generatePeerId(customPrefix);
      expect(peerId, startsWith(customPrefix));
      expect(peerId.length, greaterThan(customPrefix.length));
    });

    test('generates unique peer IDs', () {
      final peerId1 = generatePeerId();
      final peerId2 = generatePeerId();
      expect(peerId1, isNot(equals(peerId2)));
    });

    test('generates peer ID of correct length', () {
      final peerId = generatePeerId();
      // ID_PREFIX is 8 chars, base64 of 9 bytes is 12 chars = 20 total
      expect(peerId.length, equals(20));
    });
  });

  group('hexString2Buffer', () {
    test('converts valid hex string to buffer', () {
      final hexStr = '48656c6c6f';
      final result = hexString2Buffer(hexStr);
      expect(result, isNotNull);
      expect(result, equals([0x48, 0x65, 0x6c, 0x6c, 0x6f]));
    });

    test('converts empty hex string returns null', () {
      final result = hexString2Buffer('');
      expect(result, isNull);
    });

    test('converts hex string with odd length returns null', () {
      final result = hexString2Buffer('123');
      expect(result, isNull);
    });

    test('converts hex string with invalid characters returns null', () {
      final result = hexString2Buffer('GHIJ');
      expect(result, isNull);
    });

    test('converts uppercase hex string', () {
      final hexStr = 'ABCDEF';
      final result = hexString2Buffer(hexStr);
      expect(result, isNotNull);
      expect(result, equals([0xAB, 0xCD, 0xEF]));
    });

    test('converts lowercase hex string', () {
      final hexStr = 'abcdef';
      final result = hexString2Buffer(hexStr);
      expect(result, isNotNull);
      expect(result, equals([0xAB, 0xCD, 0xEF]));
    });

    test('converts mixed case hex string', () {
      final hexStr = 'AbCdEf';
      final result = hexString2Buffer(hexStr);
      expect(result, isNotNull);
      expect(result, equals([0xAB, 0xCD, 0xEF]));
    });

    test('converts single byte hex string', () {
      final hexStr = 'FF';
      final result = hexString2Buffer(hexStr);
      expect(result, isNotNull);
      expect(result, equals([0xFF]));
    });

    test('converts long hex string', () {
      final hexStr = '0123456789ABCDEF0123456789ABCDEF';
      final result = hexString2Buffer(hexStr);
      expect(result, isNotNull);
      expect(result!.length, equals(16));
      expect(result[0], equals(0x01));
      expect(result[15], equals(0xEF));
    });
  });

  group('constants', () {
    test('DEFAULT_REQUEST_LENGTH is correct', () {
      expect(DEFAULT_REQUEST_LENGTH, equals(16384)); // 2^14
    });

    test('MAX_REQUEST_LENGTH is correct', () {
      expect(MAX_REQUEST_LENGTH, equals(131072)); // 2^17
    });
  });
}
