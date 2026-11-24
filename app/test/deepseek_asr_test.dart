// DeepSeek ASR 云转写客户端红绿（假服务器）：multipart 协议对账
// （Bearer/边界/file 字段/WAV 字节无损）、200 译文解析、HTTP 错误人话、
// 空译文、超尺寸兜底、总期限超时、连接拒绝。与 voice_refine_test 同款
// 假服务器手法。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/audio_capture.dart';
import 'package:zcode_pocket/core/deepseek_asr.dart';

void main() {
  tearDown(() {
    debugAsrEndpointOverride = null;
    debugAsrTotalTimeoutOverride = null;
  });

  test('multipart 协议对账 + 译文 trim 返回', () async {
    final wav = wrapPcm16Wav(Uint8List.fromList(List.filled(3200, 7)));
    Uint8List? received;
    String? auth;
    String? contentType;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      auth = request.headers.value('authorization');
      contentType = request.headers.value('content-type');
      received = Uint8List.fromList(
        await request.fold<List<int>>([], (a, b) => a..addAll(b)),
      );
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        '{"request_id":"r1","text":" 帮我看下日志 ","duration_ms":1000}',
      );
      await request.response.close();
    });
    debugAsrEndpointOverride = 'http://127.0.0.1:${server.port}/v1/tools/asr';

    final text = await transcribeDictation(apiKey: 'sk-test', wav: wav);
    expect(text, '帮我看下日志');
    expect(auth, 'Bearer sk-test');
    expect(contentType, contains('multipart/form-data'));
    expect(contentType, contains('boundary='));
    final body = utf8.decode(received!, allowMalformed: true);
    expect(body, contains('name="file"'));
    expect(body, contains('filename="voice.wav"'));
    // WAV 字节无损嵌入 multipart body：尾边界 \r\n--<boundary>--\r\n
    // 长度 = boundary+8，其前即 payload。
    final boundary = contentType!.split('boundary=').last.trim();
    final postLen = boundary.length + 8;
    expect(
      received!.sublist(
        received!.length - postLen - wav.length,
        received!.length - postLen,
      ),
      wav,
    );
  });

  test('HTTP 错误 → 人话异常（401/429/503）', () async {
    for (final code in [401, 429, 503]) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = code;
        await request.response.close();
      });
      debugAsrEndpointOverride = 'http://127.0.0.1:${server.port}/asr';
      await expectLater(
        transcribeDictation(apiKey: 'sk-x', wav: Uint8List(44)),
        throwsA(
          isA<DeepseekAsrException>()
              .having((e) => e.code, 'code', code)
              .having((e) => e.message, 'message', deepseekAsrErrorMessage(code)),
        ),
      );
      await server.close(force: true);
    }
  });

  test('空译文返回空串（面板「没听到内容」分支收口）', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response.write('{"text":""}');
      await request.response.close();
    });
    debugAsrEndpointOverride = 'http://127.0.0.1:${server.port}/asr';
    expect(await transcribeDictation(apiKey: 'sk-x', wav: Uint8List(44)), '');
  });

  test('超 8MiB 不发起请求直接 413', () async {
    await expectLater(
      transcribeDictation(
        apiKey: 'sk-x',
        wav: Uint8List(kAsrMaxWavBytes + 1),
      ),
      throwsA(isA<DeepseekAsrException>().having((e) => e.code, 'code', 413)),
    );
  });

  test('总期限到点 → 504 人话（body 停滞形态）', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      // 头+半截 body 上线后停滞（弱网半挂形态）。
      request.response.write('{"text":');
      await request.response.flush();
    });
    debugAsrEndpointOverride = 'http://127.0.0.1:${server.port}/asr';
    debugAsrTotalTimeoutOverride = const Duration(milliseconds: 300);
    await expectLater(
      transcribeDictation(apiKey: 'sk-x', wav: Uint8List(44)),
      throwsA(isA<DeepseekAsrException>().having((e) => e.code, 'code', 504)),
    );
  });

  test('连接拒绝 → 网络人话（-1009）', () async {
    debugAsrEndpointOverride = 'http://127.0.0.1:1/asr';
    await expectLater(
      transcribeDictation(apiKey: 'sk-x', wav: Uint8List(44)),
      throwsA(
        isA<DeepseekAsrException>().having((e) => e.code, 'code', -1009),
      ),
    );
  });
}