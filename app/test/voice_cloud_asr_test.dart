// DeepSeek ASR 云转写通道回归（2026-11-24 按住说话批：controller 单测 +
// strip UI + 页面真手势）。录音/转写以缝注入，不触真实插件与网络。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/audio_capture.dart';
import 'package:zcode_pocket/core/deepseek_asr.dart';
import 'package:zcode_pocket/core/system_asr.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/voice_availability.dart';
import 'package:zcode_pocket/state/voice_dictation_controller.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

const _permCh = MethodChannel('flutter.baseflow.com/permissions/methods');
const _storageCh = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const _sysCh = MethodChannel('companion/sys_asr');
const _codec = StandardMethodCodec();

class _FakeRecorder implements VoiceRecorder {
  final Uint8List wav;
  bool started = false;
  bool stopped = false;
  bool cancelled = false;
  _FakeRecorder(this.wav);

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<Uint8List> stop() async {
    stopped = true;
    return wav;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

Uint8List _wav() => wrapPcm16Wav(Uint8List.fromList(List.filled(3200, 0)));

void _mockMicGranted() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_permCh, (call) async {
    if (call.method == 'requestPermissions' ||
        call.method == 'checkPermissions') {
      return {7: 1};
    }
    return null;
  });
}

void _mockStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_storageCh, (call) async => null);
}

({VoiceDictationController c, List<String> texts, List<String> errors})
    _makeController({AppState? app}) {
  final texts = <String>[];
  final errors = <String>[];
  final c = VoiceDictationController(
    prefs: (app ?? (AppState()..loaded = true)).uiPrefs,
    onText: (t, o, ok) => texts.add(t),
    onError: (m, s) => errors.add(m),
  );
  return (c: c, texts: texts, errors: errors);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugVoiceRecorderOverride = null;
    VoiceDictationController.debugCloudKeyOverride = null;
    VoiceDictationController.debugAsrOverride = null;
    debugVoiceRecognitionAvailable = null;
    SystemAsr.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permCh, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_storageCh, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_sysCh, null);
  });

  group('云转写 controller', () {
    testWidgets('recording→finish→finishing→onText', (tester) async {
      _mockMicGranted();
      SystemAsr.debugSetAvailable(false);
      final rec = _FakeRecorder(_wav());
      debugVoiceRecorderOverride = () => rec;
      VoiceDictationController.debugCloudKeyOverride = 'sk-x';
      final gate = Completer<String>();
      VoiceDictationController.debugAsrOverride = (_) => gate.future;
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.pushToTalk));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(rec.started, isTrue);
      expect(f.c.phase, VoiceDictationPhase.recording);

      unawaited(f.c.finish());
      await tester.pump();
      expect(f.c.phase, VoiceDictationPhase.finishing);
      gate.complete('帮我看下日志');
      await tester.pump();
      expect(rec.stopped, isTrue);
      expect(f.texts, ['帮我看下日志']);
      expect(f.c.phase, VoiceDictationPhase.idle);
      f.c.dispose();
    });

    testWidgets('转写失败人话上浮（429）', (tester) async {
      _mockMicGranted();
      SystemAsr.debugSetAvailable(false);
      debugVoiceRecorderOverride = () => _FakeRecorder(_wav());
      VoiceDictationController.debugCloudKeyOverride = 'sk-x';
      VoiceDictationController.debugAsrOverride = (_) async =>
          throw DeepseekAsrException(429, deepseekAsrErrorMessage(429));
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.toggle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      unawaited(f.c.finish());
      await tester.pump();
      await tester.pump();
      expect(f.errors, ['请求过频，请稍后重试']);
      f.c.dispose();
    });

    testWidgets('空录音 → 没听到内容', (tester) async {
      _mockMicGranted();
      SystemAsr.debugSetAvailable(false);
      debugVoiceRecorderOverride = () => _FakeRecorder(Uint8List(0));
      VoiceDictationController.debugCloudKeyOverride = 'sk-x';
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.toggle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      unawaited(f.c.finish());
      await tester.pump();
      await tester.pump();
      expect(f.errors, ['没听到内容，再试一次']);
      f.c.dispose();
    });

    testWidgets('120s 自动停 → 转写', (tester) async {
      _mockMicGranted();
      SystemAsr.debugSetAvailable(false);
      final rec = _FakeRecorder(_wav());
      debugVoiceRecorderOverride = () => rec;
      VoiceDictationController.debugCloudKeyOverride = 'sk-x';
      VoiceDictationController.debugAsrOverride = (_) async => '自动收尾';
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.pushToTalk));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 120));
      await tester.pump();
      await tester.pump();
      expect(rec.stopped, isTrue);
      expect(f.texts, ['自动收尾']);
      f.c.dispose();
    });

    testWidgets('cancel 释放麦克风（隐私）', (tester) async {
      _mockMicGranted();
      SystemAsr.debugSetAvailable(false);
      final rec = _FakeRecorder(_wav());
      debugVoiceRecorderOverride = () => rec;
      VoiceDictationController.debugCloudKeyOverride = 'sk-x';
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.pushToTalk));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(rec.started, isTrue);
      f.c.cancel();
      expect(rec.cancelled, isTrue);
      expect(f.c.phase, VoiceDictationPhase.idle);
      f.c.dispose();
    });

    testWidgets('dispose 释放麦克风（页面退出隐私）', (tester) async {
      _mockMicGranted();
      SystemAsr.debugSetAvailable(false);
      final rec = _FakeRecorder(_wav());
      debugVoiceRecorderOverride = () => rec;
      VoiceDictationController.debugCloudKeyOverride = 'sk-x';
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.pushToTalk));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      f.c.dispose();
      await tester.pump();
      expect(rec.cancelled, isTrue);
    });

    testWidgets('无 key 无系统服务 → 失败（不拾音）', (tester) async {
      _mockMicGranted();
      SystemAsr.debugSetAvailable(false);
      final rec = _FakeRecorder(_wav());
      debugVoiceRecorderOverride = () => rec;
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.toggle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(rec.started, isFalse);
      expect(f.errors, ['当前设备无可用语音服务']);
      f.c.dispose();
    });

    test('入口可用性：云 key 分支 + 复用规则', () async {
      SystemAsr.debugSetAvailable(false);
      final prefs = (AppState()..loaded = true).uiPrefs;
      expect(voiceEntryAvailableFor(prefs), isFalse);
      await prefs.setVoiceAsrApiKey('sk-asr');
      expect(prefs.deepseekAsrKey, 'sk-asr');
      expect(voiceEntryAvailableFor(prefs), isTrue);
      await prefs.setVoiceAsrApiKey('');
      await prefs.setVoiceApiProvider('deepseek');
      await prefs.setVoiceApiKey('sk-refine');
      expect(prefs.deepseekAsrKey, 'sk-refine');
      expect(voiceEntryAvailableFor(prefs), isTrue);
      await prefs.setVoiceApiProvider('zhipu');
      expect(prefs.deepseekAsrKey, isNull);
      expect(voiceEntryAvailableFor(prefs), isFalse);
    });

    testWidgets('probe 假阳：系统 error 5 零部分 → 云兜底进录音', (tester) async {
      _mockMicGranted();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_sysCh, (call) async {
        if (call.method == 'isAvailable') return true;
        return null;
      });
      SystemAsr.resetForTest();
      final app = AppState()..loaded = true;
      _mockStorage();
      await app.uiPrefs.setVoiceAsrApiKey('sk-x');
      final rec = _FakeRecorder(_wav());
      debugVoiceRecorderOverride = () => rec;
      final f = _makeController(app: app);
      unawaited(f.c.start(VoiceDictationMode.pushToTalk));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        _sysCh.name,
        _codec.encodeMethodCall(
          const MethodCall('event', {'type': 'error', 'code': 5, 'message': ''}),
        ),
        null,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(rec.started, isTrue);
      expect(f.c.phase, VoiceDictationPhase.recording);
      f.c.dispose();
    });
  });

  group('strip UI + 页面手势', () {
    Future<AppState> pumpPage(WidgetTester tester) async {
      _mockMicGranted();
      _mockStorage();
      SystemAsr.debugSetAvailable(false);
      final app = AppState()..loaded = true;
      await app.uiPrefs.setVoiceAsrApiKey('sk-x');
      await tester.pumpWidget(
        AppStateScope(
          app: app,
          child: const MaterialApp(
            home: Scaffold(
              body: ConversationPage(sessionId: null, title: '草稿'),
            ),
          ),
        ),
      );
      await tester.pump();
      return app;
    }

    testWidgets('按住说话：hold→recording→松开→文字进输入框', (tester) async {
      final rec = _FakeRecorder(_wav());
      debugVoiceRecorderOverride = () => rec;
      VoiceDictationController.debugAsrOverride = (_) async => '口述内容';
      await pumpPage(tester);
      final btn = find.byKey(const ValueKey('send-button'));
      final gesture = await tester.startGesture(tester.getCenter(btn));
      await tester.pump(const Duration(milliseconds: 600)); // 长按触发
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('voice-strip')), findsOneWidget);
      expect(rec.started, isTrue);
      await gesture.up();
      await tester.pump();
      await tester.pump();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('chat-input')),
      );
      expect(field.controller!.text, '口述内容');
      expect(find.byKey(const ValueKey('voice-strip')), findsNothing);
    });

    testWidgets('上滑取消：松开丢弃且释放麦克风', (tester) async {
      final rec = _FakeRecorder(_wav());
      debugVoiceRecorderOverride = () => rec;
      VoiceDictationController.debugAsrOverride = (_) async => '不该出现';
      await pumpPage(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('send-button'))),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, -80));
      await tester.pump();
      expect(find.text('松开取消'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      expect(rec.cancelled, isTrue);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('chat-input')),
      );
      expect(field.controller!.text, isEmpty);
    });

    testWidgets('点按麦克风不启动会话（只保留长按）', (tester) async {
      final rec = _FakeRecorder(_wav());
      debugVoiceRecorderOverride = () => rec;
      await pumpPage(tester);
      await tester.tap(find.byKey(const ValueKey('send-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(rec.started, isFalse);
      expect(find.byKey(const ValueKey('voice-strip')), findsNothing);
    });

    // 开关式会话仅经加号面板 add-voice（菜单显式选择，非麦克风短按）。
    Future<void> openToggle(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('add-trigger')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-voice')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('add-voice=开关式：strip 停止按钮收尾', (tester) async {
      final rec = _FakeRecorder(_wav());
      debugVoiceRecorderOverride = () => rec;
      VoiceDictationController.debugAsrOverride = (_) async => '开关式内容';
      await pumpPage(tester);
      await openToggle(tester);
      expect(find.byKey(const ValueKey('voice-strip-stop')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('voice-strip-stop')));
      await tester.pump();
      await tester.pump();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('chat-input')),
      );
      expect(field.controller!.text, '开关式内容');
    });

    testWidgets('add-voice 开关式：strip 取消按钮丢弃会话', (tester) async {
      final rec = _FakeRecorder(_wav());
      debugVoiceRecorderOverride = () => rec;
      await pumpPage(tester);
      await openToggle(tester);
      await tester.tap(find.byKey(const ValueKey('voice-strip-cancel')));
      await tester.pump();
      expect(rec.cancelled, isTrue);
      expect(find.byKey(const ValueKey('voice-strip')), findsNothing);
    });
  });
}