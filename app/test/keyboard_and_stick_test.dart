import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/audio_capture.dart';
import 'package:zcode_pocket/core/system_asr.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/state/voice_dictation_controller.dart';
import 'package:zcode_pocket/state/voice_availability.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

/// 2026-10-23 用户反馈两件回归：
/// ① 流式输出不持续粘底——解除粘底后（上滑回看）手动滑回底部不恢复
///    跟随，得点悬浮球才行；官方网页端贴底即恢复。断言链：拖回底部后
///    视口缩小（键盘弹起）仍自动贴底=粘底已恢复。
/// ② 语音面板被输入法盖住——showVoiceInputSheet 补 viewInsets 垫高。
class _CacheAppState extends AppState {
  _CacheAppState(this.rows);
  final List<Map<String, dynamic>> rows;

  @override
  Future<SessionCacheEntry?> readSessionCache(String id) async =>
      SessionCacheEntry(
        deviceSid: 'd1',
        sessionId: id,
        rows: rows,
        logEpoch: 'e1',
        lastSeq: rows.length,
        firstRowId: 1,
        totalCount: rows.length,
        snapshotControl: null,
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
}

Widget _host(AppState app, Widget page) => AppStateScope(
      app: app,
      child: MaterialApp(home: page),
    );

List<Map<String, dynamic>> _tallRows() => [
      for (var i = 0; i < 60; i++)
        {
          'rowId': i + 1,
          'kind': i.isEven ? 'userInput' : 'assistantText',
          'text': '消息 $i——占位文本，撑出足够滚动高度。',
        },
    ];

ScrollPosition _pos(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('chat-scroll')),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

/// 多机型批（6.1）：测试屏宽常量化（原 360 写死——改参便于小屏变体）。
const kTestPhoneW = 360.0;

void main() {
  testWidgets('① 滑回底部重新粘底：视口缩小仍自动贴底', (tester) async {
    tester.view.physicalSize = const Size(kTestPhoneW, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final app = _CacheAppState(_tallRows());
    await tester.pumpWidget(
      _host(app, const ConversationPage(sessionId: 's1', title: '会话')),
    );
    // 缓存预渲链跨多帧，有界泵到稳定。
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final pos = _pos(tester);
    expect(pos.maxScrollExtent, greaterThan(300), reason: '前置：内容足够高');
    expect(pos.pixels, pos.maxScrollExtent, reason: '前置：打开即在底部');

    // 回看历史（手指向下拖=向旧内容方向），解除粘底：位置停在半途不回吸。
    await tester.drag(find.byKey(const ValueKey('chat-scroll')), const Offset(0, 260));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(pos.maxScrollExtent - pos.pixels, greaterThan(100),
        reason: '解除粘底后不应回吸底部');

    // 滑回底部（修复点）：贴底即恢复粘底。
    while (pos.maxScrollExtent - pos.pixels > 1) {
      await tester.drag(
        find.byKey(const ValueKey('chat-scroll')),
        const Offset(0, -400),
        warnIfMissed: false,
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(pos.pixels, pos.maxScrollExtent, reason: '已滑回底部');

    // 视口缩小（键盘弹起）：粘底恢复则自动跟到新底；未恢复则停在旧 offset。
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      pos.pixels,
      pos.maxScrollExtent,
      reason: '滑回底部后粘底应已恢复——键盘弹起（视口缩小）仍自动贴底',
    );
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('② 语音 inline 条带随键盘垫高（不被输入法遮挡）', (tester) async {
    tester.view.physicalSize = const Size(kTestPhoneW, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 云转写缝：点按麦克风进入开关式 recording，strip 在场。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (call) async {
        if (call.method == 'requestPermissions' ||
            call.method == 'checkPermissions') {
          return {7: 1};
        }
        return null;
      },
    );
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/permissions/methods'),
          null,
        ));
    SystemAsr.debugSetAvailable(false);
    addTearDown(SystemAsr.resetForTest);
    debugVoiceRecognitionAvailable = true;
    addTearDown(() => debugVoiceRecognitionAvailable = null);
    debugVoiceRecorderOverride = () => _NoopRecorder();
    addTearDown(() => debugVoiceRecorderOverride = null);
    VoiceDictationController.debugCloudKeyOverride = 'sk-x';
    addTearDown(() => VoiceDictationController.debugCloudKeyOverride = null);

    await tester.pumpWidget(
      _host(AppState()..loaded = true,
          const ConversationPage(sessionId: null, title: '草稿')),
    );
    await tester.pump();
    // 只保留长按：按住启动 recording（不松开，保持会话活跃）。
    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('send-button'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 100));
    final strip = find.byKey(const ValueKey('voice-strip'));
    expect(strip, findsOneWidget);

    // 键盘弹起：Scaffold _resize 把输入栏+条带顶到键盘上方。
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final box = tester.renderObject<RenderBox>(strip);
    expect(
      box.localToGlobal(Offset.zero).dy + box.size.height,
      lessThanOrEqualTo(780 - 260),
      reason: '键盘弹起时语音条带应在键盘上方（不重叠）',
    );
    await g.up();
    await tester.pump();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump(const Duration(milliseconds: 100));
  });
}

class _NoopRecorder implements VoiceRecorder {
  @override
  Future<void> start() async {}
  @override
  Future<Uint8List> stop() async =>
      wrapPcm16Wav(Uint8List.fromList(List.filled(3200, 0)));
  @override
  Future<void> cancel() async {}
}
