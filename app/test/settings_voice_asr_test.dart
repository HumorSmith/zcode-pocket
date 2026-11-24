// 设置·语音输入子页「识别引擎」节回归：系统服务状态行、DeepSeek
// 转写 key 对话框存取、留空复用整理 key 的副标题联动。存储处理与
// settings_voice_provider_test 同款（setter 自吞写失败）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/system_asr.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/ui/settings_page.dart';
import 'package:zcode_pocket/ui/settings_voice_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // widget 测试假异步不推进真实存储通道回包——pump 外 await setter
  // 会死锁；mock 即答（与 voice_cloud_asr_test 同款）。
  const storageCh = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageCh, (call) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageCh, null);
    SystemAsr.resetForTest();
  });

  Future<void> pumpVoice(WidgetTester tester, AppState app) async {
    await tester.pumpWidget(
      AppStateScope(app: app, child: const MaterialApp(home: SettingsPage())),
    );
    await tester.tap(find.text('语音输入'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('系统语音服务'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  testWidgets('系统缺席：状态行不可用；key 对话框存取联动', (tester) async {
    SystemAsr.debugSetAvailable(false);
    final app = AppState()..loaded = true;
    await pumpVoice(tester, app);
    expect(find.byType(SettingsVoicePage), findsOneWidget);
    expect(find.text('不可用（本机无系统识别服务）'), findsOneWidget);
    expect(
      find.text('未设置——系统服务不可用时语音入口隐藏'),
      findsOneWidget,
    );

    await tester.tap(find.text('DeepSeek 转写 API key（可选）'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('voice-asr-key-input')),
      'sk-asr',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(app.uiPrefs.voiceAsrApiKey, 'sk-asr');
    expect(app.uiPrefs.deepseekAsrKey, 'sk-asr');
    expect(find.text('已设置（key 仅存本机）'), findsOneWidget);
  });

  testWidgets('留空且提供商 DeepSeek：副标题显示复用整理 key', (tester) async {
    SystemAsr.debugSetAvailable(false);
    final app = AppState()..loaded = true;
    await app.uiPrefs.setVoiceApiProvider('deepseek');
    await app.uiPrefs.setVoiceApiKey('sk-refine');
    await pumpVoice(tester, app);
    expect(find.text('未单独设置——复用整理 key'), findsOneWidget);
  });

  testWidgets('系统在场：状态行可用（优先实时上屏）', (tester) async {
    SystemAsr.debugSetAvailable(true);
    final app = AppState()..loaded = true;
    await pumpVoice(tester, app);
    expect(find.text('可用（优先，实时上屏）'), findsOneWidget);
  });
}