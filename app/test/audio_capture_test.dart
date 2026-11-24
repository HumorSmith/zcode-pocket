// WAV（PCM16）封装回归：44 字节头字段逐一对账 + payload 无损。
// 采集层（record 插件）不进 Flutter 测试——真机冒烟覆盖。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/audio_capture.dart';

void main() {
  test('单声道 16k：头字段与 payload 对账', () {
    final pcm = Uint8List.fromList(List.generate(6400, (i) => i % 256));
    final wav = wrapPcm16Wav(pcm);
    final b = ByteData.sublistView(wav);

    String ascii(int o, int n) =>
        String.fromCharCodes(wav.sublist(o, o + n));
    expect(ascii(0, 4), 'RIFF');
    expect(b.getUint32(4, Endian.little), 36 + pcm.length);
    expect(ascii(8, 4), 'WAVE');
    expect(ascii(12, 4), 'fmt ');
    expect(b.getUint32(16, Endian.little), 16);
    expect(b.getUint16(20, Endian.little), 1); // PCM
    expect(b.getUint16(22, Endian.little), 1); // mono
    expect(b.getUint32(24, Endian.little), 16000);
    expect(b.getUint32(28, Endian.little), 16000 * 2); // byteRate
    expect(b.getUint16(32, Endian.little), 2); // blockAlign
    expect(b.getUint16(34, Endian.little), 16);
    expect(ascii(36, 4), 'data');
    expect(b.getUint32(40, Endian.little), pcm.length);
    expect(wav.length, 44 + pcm.length);
    expect(wav.sublist(44), pcm);
  });

  test('立体声参数：blockAlign/byteRate 随声道数', () {
    final wav = wrapPcm16Wav(Uint8List(8), sampleRate: 8000, channels: 2);
    final b = ByteData.sublistView(wav);
    expect(b.getUint16(22, Endian.little), 2);
    expect(b.getUint32(24, Endian.little), 8000);
    expect(b.getUint32(28, Endian.little), 8000 * 4);
    expect(b.getUint16(32, Endian.little), 4);
  });

  test('空 PCM：合法零长 data 段', () {
    final wav = wrapPcm16Wav(Uint8List(0));
    expect(wav.length, 44);
    expect(ByteData.sublistView(wav).getUint32(40, Endian.little), 0);
  });
}