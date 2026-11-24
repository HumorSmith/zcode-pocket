import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// DeepSeek ASR 云转写（批处理通道）：录完再转写，整段 multipart 上传、
/// 整段译文返回。端点规格来源（2026-11-24 官方文档 /guides/asr/）：
/// POST /v1/tools/asr，Bearer 同账号 key，file 字段 16-bit PCM WAV /
/// Ogg Opus，≤120s / ≤8MiB，**不支持流式**，中文自动检测。
/// 与 voice_refine.dart 同款：纯 dart:io、用户自己的 key、总期限预算、
/// 失败人话上浮（决策 24）。系统识别服务可用时不走本通道（实时上屏
/// 优先，见 voice_dictation_controller 分派）。

const kAsrEndpoint = 'https://api.deepseek.com/v1/tools/asr';

/// API 侧硬上限（官方文档）：120s / 8MiB。采集层 120s 自动停，
/// 这里兜底防超尺寸上传。
const kAsrMaxDuration = Duration(seconds: 120);
const kAsrMaxWavBytes = 8 * 1024 * 1024;

/// 转写请求总期限：上传+识别。短音频往返通常数秒；30s 覆盖弱网
/// 3.8MB（120s 单声道 16k WAV）上传。
const kAsrTotalTimeout = Duration(seconds: 30);

/// 测试缝：覆盖请求端点（null=官方端点）——假服务器红绿专用。
@visibleForTesting
String? debugAsrEndpointOverride;

/// 测试缝：覆盖总期限（null=生产 [kAsrTotalTimeout]）。
@visibleForTesting
Duration? debugAsrTotalTimeoutOverride;

/// 转写失败（code=HTTP 状态或自定义负码），message 为人话，面板直显。
class DeepseekAsrException implements Exception {
  final int code;
  final String message;
  const DeepseekAsrException(this.code, this.message);
  @override
  String toString() => message;
}

/// HTTP/自定义码 → 人话（与 iosVoiceErrorMessage 同形）。
String deepseekAsrErrorMessage(int code) {
  switch (code) {
    case 401 || 403:
      return 'API key 无效或无权限，请在设置中检查';
    case 400:
      return '音频格式不受支持，请重试';
    case 408:
      return '上传超时，请重试或改用键盘输入';
    case 413:
      return '录音过长，请缩短后重试';
    case 429:
      return '请求过频，请稍后重试';
    case 503:
      return '服务繁忙，请稍后重试';
    case 504:
      return '转写超时，请重试或改用键盘输入';
    case -1009:
      return '网络连接不可用，请检查网络';
    default:
      return '语音服务未响应，请重试或改用键盘输入';
  }
}

/// 整段转写。空译文返回 ''——面板 _enterPreview 空文本分支收口为
/// 「没听到内容」，与系统通道语义一致。
Future<String> transcribeDictation({
  required String apiKey,
  required Uint8List wav,
}) async {
  if (wav.length > kAsrMaxWavBytes) {
    throw DeepseekAsrException(413, deepseekAsrErrorMessage(413));
  }
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  // 总期限预算（refineDictation 同款）：分档上限与总期限剩余取较小值。
  final totalTimeout = debugAsrTotalTimeoutOverride ?? kAsrTotalTimeout;
  final elapsed = Stopwatch()..start();
  Duration remaining(Duration cap) {
    final left = totalTimeout - elapsed.elapsed;
    if (left <= Duration.zero) return const Duration(milliseconds: 1);
    return left < cap ? left : cap;
  }

  try {
    final boundary = '----zpvoiceasr${DateTime.now().microsecondsSinceEpoch}';
    final req = await client
        .postUrl(Uri.parse(debugAsrEndpointOverride ?? kAsrEndpoint))
        .timeout(remaining(const Duration(seconds: 8)));
    req.headers.set('Authorization', 'Bearer $apiKey');
    req.headers.contentType = ContentType(
      'multipart',
      'form-data',
      parameters: {'boundary': boundary},
    );
    final body = _multipartBody(boundary, wav);
    req.contentLength = body.length;
    req.add(body);
    final res =
        await req.close().timeout(remaining(const Duration(seconds: 12)));
    final text = await res
        .transform(utf8.decoder)
        .join()
        .timeout(remaining(totalTimeout));
    if (res.statusCode != 200) {
      throw DeepseekAsrException(
        res.statusCode,
        deepseekAsrErrorMessage(res.statusCode),
      );
    }
    final decoded = jsonDecode(text);
    final t = decoded is Map ? decoded['text'] : null;
    return t is String ? t.trim() : '';
  } on DeepseekAsrException {
    rethrow;
  } on TimeoutException {
    throw DeepseekAsrException(504, deepseekAsrErrorMessage(504));
  } on SocketException {
    throw DeepseekAsrException(-1009, deepseekAsrErrorMessage(-1009));
  } catch (e) {
    _log('asr failed: $e');
    throw DeepseekAsrException(-1, deepseekAsrErrorMessage(-1));
  } finally {
    client.close();
  }
}

void _log(String line) => debugPrint('[voice] $line');

Uint8List _multipartBody(String boundary, Uint8List wav) {
  final pre = utf8.encode(
    '--$boundary\r\n'
    'Content-Disposition: form-data; name="file"; filename="voice.wav"\r\n'
    'Content-Type: audio/wav\r\n'
    '\r\n',
  );
  final post = utf8.encode('\r\n--$boundary--\r\n');
  final out = BytesBuilder(copy: false);
  out.add(pre);
  out.add(wav);
  out.add(post);
  return out.takeBytes();
}