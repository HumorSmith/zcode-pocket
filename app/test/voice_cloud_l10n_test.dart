// 英文·按住说话 inline 条带各相位无未翻译项（2026-11-24 按住说话批，
// localized_remaining 同款 collectMissing 机制）+ 新串 EN 词表锁。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/audio_capture.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/core/system_asr.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/voice_dictation_controller.dart';
import 'package:zcode_pocket/ui/voice_dictation_strip.dart';

const _permCh = MethodChannel('flutter.baseflow.com/permissions/methods');

class _FakeRecorder implements VoiceRecorder {
  @override
  Future<void> start() async {}
  @override
  Future<Uint8List> stop() async =>
      wrapPcm16Wav(Uint8List.fromList(List.filled(3200, 0)));
  @override
  Future<void> cancel() async {}
}

void _expectNoMissing(String label) {
  expect(
    L10n.missingTranslations,
    isEmpty,
    reason: '$label 英文未命中：${L10n.missingTranslations.join(' | ')}',
  );
  L10n.resetForTest();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugVoiceRecorderOverride = null;
    VoiceDictationController.debugCloudKeyOverride = null;
    VoiceDictationController.debugAsrOverride = null;
    SystemAsr.resetForTest();
    L10n.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permCh, null);
  });

  test('新串 EN 词表锁（条带+snackbar）', () {
    L10n.setTestLocale('en-US');
    expect(tr('正在听你说，松开转写'), 'Listening — release to transcribe');
    expect(tr('松开转写 · 上滑取消'), 'Release to transcribe · slide up to cancel');
    expect(tr('松开取消'), 'Release to cancel');
    expect(tr('录音最长 2 分钟'), 'Up to 2 minutes per recording');
    expect(tr('已按口语整理'), 'Polished from speech');
    expect(tr('用原文'), 'Use original');
    L10n.resetForTest();
  });

  testWidgets('英文·recording/listening/finishing/取消态 无未翻译项',
      (tester) async {
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permCh, (call) async {
      if (call.method == 'requestPermissions' ||
          call.method == 'checkPermissions') {
        return {7: 1};
      }
      return null;
    });
    SystemAsr.debugSetAvailable(false);
    debugVoiceRecorderOverride = () => _FakeRecorder();
    VoiceDictationController.debugCloudKeyOverride = 'sk-x';
    final gate = Completer<String>();
    VoiceDictationController.debugAsrOverride = (_) => gate.future;
    final c = VoiceDictationController(
      prefs: (AppState()..loaded = true).uiPrefs,
      onText: (_, __, ___) {},
      onError: (_, __) {},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: VoiceDictationStrip(controller: c)),
      ),
    );
    unawaited(c.start(VoiceDictationMode.pushToTalk));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    _expectNoMissing('strip recording');

    c.armCancel(true);
    await tester.pump();
    _expectNoMissing('strip cancel armed');
    c.armCancel(false);

    unawaited(c.finish());
    await tester.pump();
    _expectNoMissing('strip finishing');
    gate.complete('check the logs');
    await tester.pump();
    _expectNoMissing('strip idle after text');
    c.dispose();
  });

  testWidgets('英文·开关式 listening 无未翻译项', (tester) async {
    L10n.setTestLocale('en-US');
    L10n.collectMissing = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permCh, (call) async {
      if (call.method == 'requestPermissions' ||
          call.method == 'checkPermissions') {
        return {7: 1};
      }
      return null;
    });
    // 系统通道 mock：isAvailable=true，start 后推 partial。
    const sysCh = MethodChannel('companion/sys_asr');
    const codec = StandardMethodCodec();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sysCh, (call) async {
      if (call.method == 'isAvailable') return true;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sysCh, null));
    SystemAsr.resetForTest();
    final c = VoiceDictationController(
      prefs: (AppState()..loaded = true).uiPrefs,
      onText: (_, __, ___) {},
      onError: (_, __) {},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: VoiceDictationStrip(controller: c)),
      ),
    );
    unawaited(c.start(VoiceDictationMode.toggle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      sysCh.name,
      codec.encodeMethodCall(
        const MethodCall('event', {'type': 'partial', 'text': 'hello'}),
      ),
      null,
    );
    await tester.pump();
    _expectNoMissing('strip toggle listening');
    c.dispose();
  });
}