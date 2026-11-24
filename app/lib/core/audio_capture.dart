import 'dart:async';
import 'dart:typed_data';

import 'package:audio_streamer/audio_streamer.dart';
import 'package:flutter/foundation.dart';

/// 语音云转写（DeepSeek ASR 批处理通道）的采集层：audio_streamer
/// PCM 流（单声道）→ Dart 侧 int16 累积 → WAV 封装。内存持有、不落盘
/// （比临时文件形态更干净：cancel 即弃，无残留）。系统/HMS 通道不经过
/// 本层——它们的拾音由各自引擎承担。
///
/// 隐私纪律与原生通道同款：stop/cancel 必须停止拾音（取消订阅触发
/// 原生 onCancel）。
///
/// 采样率：Android 可请求 16k；iOS 仅偏好值（实际可能 44.1k/48k），
/// 以 actualSampleRate 入 WAV 头（DeepSeek 接受 8k–48k）。注意 48k 单声道
/// 120s ≈ 11.5MB 超 API 8MiB 上限——超尺寸由转写客户端 413 人话兜底
/// （iOS 通常有系统识别服务，云通道极少触达）。

const kVoiceSampleRate = 16000;

/// WAV（PCM16）封装：44 字节标准头 + 原始 PCM。纯函数，可红绿。
Uint8List wrapPcm16Wav(
  Uint8List pcm, {
  int sampleRate = kVoiceSampleRate,
  int channels = 1,
}) {
  final header = ByteData(44);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  final blockAlign = channels * 2;
  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * blockAlign, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  final out = BytesBuilder(copy: false);
  out.add(header.buffer.asUint8List());
  out.add(pcm);
  return out.takeBytes();
}

/// 一次录音会话：start→stop（吐 WAV）/cancel。与 SystemAsrSession
/// 契约同形，状态机复用同一套守卫。
abstract class VoiceRecorder {
  Future<void> start();
  Future<Uint8List> stop();
  Future<void> cancel();
}

/// 测试缝：注入假录音器（null=生产 audio_streamer 实现）。
@visibleForTesting
VoiceRecorder Function()? debugVoiceRecorderOverride;

VoiceRecorder createVoiceRecorder() =>
    debugVoiceRecorderOverride?.call() ?? StreamVoiceRecorder();

/// audio_streamer 实现：订阅 PCM 流累积 int16；取消订阅即停拾音。
class StreamVoiceRecorder implements VoiceRecorder {
  final AudioStreamer _streamer = AudioStreamer();
  final BytesBuilder _pcm = BytesBuilder(copy: false);
  StreamSubscription<List<double>>? _sub;
  bool _started = false;

  @override
  Future<void> start() async {
    _streamer.sampleRate = kVoiceSampleRate;
    _sub = _streamer.audioStream.listen((samples) {
      final bytes = Uint8List(samples.length * 2);
      final bd = ByteData.sublistView(bytes);
      for (var i = 0; i < samples.length; i++) {
        final v = samples[i].clamp(-1.0, 1.0);
        bd.setInt16(i * 2, (v * 32767).round(), Endian.little);
      }
      _pcm.add(bytes);
    });
    _started = true;
  }

  @override
  Future<Uint8List> stop() async {
    if (!_started) return Uint8List(0);
    _started = false;
    await _sub?.cancel();
    _sub = null;
    var rate = kVoiceSampleRate;
    try {
      rate = await _streamer.actualSampleRate;
    } catch (_) {
      // 原生侧已释放等异常容忍——请求值兜底（Android 即 16k）。
    }
    return wrapPcm16Wav(_pcm.takeBytes(), sampleRate: rate);
  }

  @override
  Future<void> cancel() async {
    _started = false;
    await _sub?.cancel();
    _sub = null;
    _pcm.clear();
  }
}