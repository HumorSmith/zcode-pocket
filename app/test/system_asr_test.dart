// 系统语音识别通道回归（2026-10-28 语音泛用批）：SystemAsr 客户端
// 通道协议（probe 三态 / start-stop-cancel / partial·final·error 事件
// 分发 / cancel 后事件忽略）+ 听写控制器分派/护栏单测（2026-11-24
// 按住说话批：模态面板退役，原面板端到端组平移为 controller 单测）。
// 原生侧（SystemAsrPlugin.kt）不进 Flutter 测试——真机/模拟器冒烟覆盖。
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/hms_asr.dart';
import 'package:zcode_pocket/core/system_asr.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/voice_availability.dart';
import 'package:zcode_pocket/state/voice_dictation_controller.dart';

const _ch = MethodChannel('companion/sys_asr');
const _permCh = MethodChannel('flutter.baseflow.com/permissions/methods');
const _codec = StandardMethodCodec();

/// 模拟原生侧推送事件（原生→Dart 方向）。
void _pushEvent(Map<String, dynamic> args) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    _ch.name,
    _codec.encodeMethodCall(MethodCall('event', args)),
    null,
  );
}

/// 权限通道 mock：request/check 返回固定麦克风状态（permission_handler
/// 的 microphone=7，denied=0/granted=1），openAppSettings 记录调用。
void _mockPermissionChannel({
  required int micStatus,
  void Function()? onOpenSettings,
}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_permCh, (call) async {
    switch (call.method) {
      case 'requestPermissions' || 'checkPermissions':
        return {7: micStatus};
      case 'openAppSettings':
        onOpenSettings?.call();
        return true;
    }
    return null;
  });
}

/// 控制器夹具：收集 onText/onError，prefs 来自 AppState（内存态）。
({VoiceDictationController c, List<String> texts, List<String> errors, List<bool> settings})
    _makeController({AppState? app}) {
  final texts = <String>[];
  final errors = <String>[];
  final settings = <bool>[];
  final c = VoiceDictationController(
    prefs: (app ?? (AppState()..loaded = true)).uiPrefs,
    onText: (t, o, ok) => texts.add(t),
    onError: (m, s) {
      errors.add(m);
      settings.add(s);
    },
  );
  return (c: c, texts: texts, errors: errors, settings: settings);
}

void main() {
  // 1.0.1 验收红绿：构建传 VOICE_HMS=1 时 bool.fromEnvironment 恒
  // false（只认 'true'）——统一 String 语义后 '1'/'true' 均开。
  test('voiceHmsDefineEnabled：1/true/True 开，其余关（构建=1 回归锁）', () {
    expect(voiceHmsDefineEnabled('1'), isTrue,
        reason: '构建脚本传 --dart-define=VOICE_HMS=1（起）');
    expect(voiceHmsDefineEnabled('true'), isTrue);
    expect(voiceHmsDefineEnabled(' True '), isTrue);
    expect(voiceHmsDefineEnabled('false'), isFalse);
    expect(voiceHmsDefineEnabled(''), isFalse);
    expect(voiceHmsDefineEnabled('0'), isFalse);
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    SystemAsr.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ch, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'isAvailable':
          return true;
        case 'start' || 'stop' || 'cancel':
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ch, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_permCh, null);
    SystemAsr.resetForTest();
    debugVoiceRecognitionAvailable = null;
    debugVoiceHmsOverride = null;
    VoiceDictationController.debugRefineOverride = null;
    VoiceDictationController.debugIosAsrErrorsOverride = null;
  });

  group('SystemAsr 客户端协议', () {
    test('probe：isAvailable=true → available=true（缓存）', () async {
      expect(await SystemAsr.probe(), isTrue);
      expect(SystemAsr.available, isTrue);
      expect(calls.map((c) => c.method), contains('isAvailable'));
    });

    testWidgets('probe：原生异常 → 安全回落 false', (tester) async {
      SystemAsr.resetForTest();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_ch, (call) async {
        throw PlatformException(code: 'boom');
      });
      expect(await SystemAsr.probe(), isFalse);
    });

    testWidgets('probe：瞬时 PlatformException 不落缓存（下次再探，开源'
        '审查 P1 P3-4——修复前：开机识别服务暂不可用被永久缓存 false，'
        '本会话语音入口隐藏到重启）', (tester) async {
      SystemAsr.resetForTest();
      var available = false; // 第一次：服务暂不可用抛错；第二次：恢复
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_ch, (call) async {
        if (!available) throw PlatformException(code: 'transient');
        return true;
      });
      expect(await SystemAsr.probe(), isFalse, reason: '异常本次仍安全回落');
      expect(SystemAsr.available, isFalse, reason: '缓存未被瞬时错误污染');
      available = true;
      expect(await SystemAsr.probe(), isTrue,
          reason: '修复前红：false 已被缓存，服务恢复也探测不到');
    });

    testWidgets('probeIfUnknown：消费点兜底重探（入口不会整会话隐藏）',
        (tester) async {
      SystemAsr.resetForTest();
      var available = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_ch, (call) async {
        if (!available) throw PlatformException(code: 'boot');
        return true;
      });
      expect(await SystemAsr.probe(), isFalse, reason: '开机瞬时失败');
      expect(SystemAsr.available, isFalse);
      available = true;
      SystemAsr.probeRetryInterval = Duration.zero;
      // 模拟 UI 求值（voiceRecognitionAvailable 的消费点）——缓存为空
      // 时按节流重探。
      expect(voiceRecognitionAvailable, isFalse);
      for (var i = 0; i < 5 && !SystemAsr.available; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(SystemAsr.available, isTrue,
          reason: '重探成功后入口在下一次重建可见（修复前只有 main 探一次）');
      expect(voiceRecognitionAvailable, isTrue);
    });

    testWidgets('session：partial→final 事件分发', (tester) async {
      final partials = <String>[];
      String? finalText;
      Object? err;
      final session = SystemAsr.start(
        onPartial: partials.add,
        onFinal: (t) => finalText = t,
        onError: (c, m) => err = '$c:$m',
      );
      await tester.pump();
      expect(calls.map((c) => c.method), contains('start'));

      _pushEvent({'type': 'partial', 'text': '你好'});
      await tester.pump();
      _pushEvent({'type': 'partial', 'text': '你好世界'});
      await tester.pump();
      _pushEvent({'type': 'final', 'text': '你好世界。'});
      await tester.pump();

      expect(partials, ['你好', '你好世界']);
      expect(finalText, '你好世界。');
      expect(err, isNull);
      await session.cancel();
    });

    testWidgets('session：error 事件分发（code/message）', (tester) async {
      String? finalText;
      Object? err;
      final session = SystemAsr.start(
        onPartial: (_) {},
        onFinal: (t) => finalText = t,
        onError: (c, m) => err = [c, m],
      );
      await tester.pump();
      _pushEvent({'type': 'error', 'code': 7, 'message': 'no match'});
      await tester.pump();
      expect(finalText, isNull);
      expect(err, isNotNull);
      await session.cancel();
    });

    testWidgets('session：cancel 后事件不再分发', (tester) async {
      var finalCount = 0;
      final session = SystemAsr.start(
        onPartial: (_) {},
        onFinal: (_) => finalCount++,
        onError: (_, __) {},
      );
      await tester.pump();
      await session.cancel();
      _pushEvent({'type': 'final', 'text': '迟到的事件'});
      await tester.pump();
      expect(finalCount, 0);
    });

    testWidgets('session：会话重叠时迟到 cancel 不摘后继会话的 handler'
        '（开源审查 P1 P3-3/P2 P2-4——修复前：A.cancel 无差别置 null，'
        'B 完全失聪=final/error 全丢）', (tester) async {
      final aFinals = <String>[];
      final bFinals = <String>[];
      final a = SystemAsr.start(
        onPartial: (_) {},
        onFinal: aFinals.add,
        onError: (_, __) {},
      );
      await tester.pump();
      // B 后启动（单槽被 B 占据是 API 允许的形态），A 的 cancel 迟到。
      final b = SystemAsr.start(
        onPartial: (_) {},
        onFinal: bFinals.add,
        onError: (_, __) {},
      );
      await tester.pump();
      await a.cancel();
      await tester.pump();
      _pushEvent({'type': 'final', 'text': 'B 的终稿'});
      await tester.pump();
      expect(bFinals, ['B 的终稿'],
          reason: '修复前红：A.cancel 把槽位清 null，B 的事件无人分发');
      expect(aFinals, isEmpty, reason: 'A 已取消，迟到事件不分发');
      await b.cancel();
    });

    testWidgets('session：start 传递识别语言（跟随 app 语言，Q1 P3-8）',
        (tester) async {
      final session = SystemAsr.start(
        language: 'en-US',
        onPartial: (_) {},
        onFinal: (_) {},
        onError: (_, __) {},
      );
      await tester.pump();
      final startCall = calls.firstWhere((c) => c.method == 'start');
      expect((startCall.arguments as Map)['language'], 'en-US');
      await session.cancel();
    });
  });

  group('HmsAsr 客户端（单槽守卫镜像，开源审查 P1 P3-3）', () {
    const hmsCh = MethodChannel('companion/hms_asr');

    void pushHmsEvent(Map<String, dynamic> args) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        hmsCh.name,
        _codec.encodeMethodCall(MethodCall('event', args)),
        null,
      );
    }

    testWidgets('迟到 cancel 不摘后继会话的 handler', (tester) async {
      final hmsCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hmsCh, (call) async {
        hmsCalls.add(call);
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hmsCh, null));
      final bFinals = <String>[];
      final a = HmsAsr.start(
        onPartial: (_) {},
        onFinal: (_) {},
        onError: (_, __) {},
      );
      final b = HmsAsr.start(
        language: 'en-US',
        onPartial: (_) {},
        onFinal: bFinals.add,
        onError: (_, __) {},
      );
      await tester.pump();
      await a.cancel();
      await tester.pump();
      pushHmsEvent({'type': 'final', 'text': 'B 的终稿'});
      await tester.pump();
      expect(bFinals, ['B 的终稿'],
          reason: '与系统通道同款守卫：迟到 cancel 只摘自己的槽位');
      // 本用例先后起了 A（默认 zh-CN）与 B（en-US）两会话——须取
      // 最后一条 start（firstWhere 会拿到 A 的调用）。
      final startCall =
          hmsCalls.lastWhere((c) => c.method == 'start');
      expect((startCall.arguments as Map)['language'], 'en-US');
      await b.cancel();
    });
  });

  group('通道判定（系统默认/HMS 仅覆盖/隐藏）', () {
    // 脱敏翻转：默认构建 hmsVoiceConfigured=false（VOICE_HMS
    // dart-define 缺省），系统通道是主体；HMS 仅经覆盖变量或测试缝打开。
    test('默认构建：HMS 通道关闭', () {
      expect(hmsVoiceConfigured, isFalse,
          reason: '公开默认形态不得携带私有引擎（VOICE_HMS 缺省=false）');
    });

    test('HMS 覆盖打开：即使无系统服务也恒可用', () {
      debugVoiceHmsOverride = true;
      SystemAsr.debugSetAvailable(false);
      expect(hmsVoiceConfigured, isTrue);
      expect(voiceRecognitionAvailable, isTrue);
    });

    test('系统可用（默认构建）→ 语音入口在场', () {
      SystemAsr.debugSetAvailable(true);
      expect(voiceRecognitionAvailable, isTrue,
          reason: '系统识别可用即默认档，入口应显示');
    });

    test('系统不可用且未开 HMS 覆盖 → 入口隐藏（开源自建包默认形态）', () {
      SystemAsr.debugSetAvailable(false);
      expect(voiceRecognitionAvailable, isFalse);
    });

    test('测试缝覆写优先于两级探测', () {
      SystemAsr.debugSetAvailable(true);
      debugVoiceRecognitionAvailable = false;
      expect(voiceRecognitionAvailable, isFalse);
    });
  });

  group('控制器分派与护栏（原面板端到端组平移）', () {
    testWidgets('权限授权 → start 被调 → partial 上屏 → listening 态',
        (tester) async {
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.pushToTalk));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(calls.map((c) => c.method), contains('start'),
          reason: '无 HMS 配置时必须分派到系统通道');
      _pushEvent({'type': 'partial', 'text': '在听你说话'});
      await tester.pump();
      expect(f.c.phase, VoiceDictationPhase.listening);
      expect(f.c.partial, '在听你说话');
      f.c.dispose();
    });

    testWidgets('零回调看门狗：10s 无任何引擎事件 → 明确失败（验收 G）',
        (tester) async {
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.pushToTalk));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls.map((c) => c.method), contains('start'));

      await tester.pump(const Duration(seconds: 11));
      expect(f.errors.join(), contains('语音服务未响应'));
      expect(f.c.phase, VoiceDictationPhase.idle);
      f.c.dispose();
    });

    testWidgets('零回调看门狗：引擎事件到达即解除', (tester) async {
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.pushToTalk));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      _pushEvent({'type': 'partial', 'text': '活着'});
      await tester.pump();
      await tester.pump(const Duration(seconds: 11));
      expect(f.errors, isEmpty);
      expect(f.c.partial, '活着');
      f.c.dispose();
    });

    testWidgets('引擎 error 先到立即失败（不悬挂）', (tester) async {
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.pushToTalk));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      _pushEvent({'type': 'error', 'code': 4, 'message': 'server busy'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(f.errors.join(), contains('识别失败'));
      expect(f.c.phase, VoiceDictationPhase.idle);
      f.c.dispose();
    });

    testWidgets('finish 有部分结果 → 立即按部分结果收尾', (tester) async {
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.toggle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      _pushEvent({'type': 'partial', 'text': '部分识别文字'});
      await tester.pump();
      unawaited(f.c.finish());
      await tester.pump(const Duration(milliseconds: 300));
      expect(f.texts, ['部分识别文字']);
      f.c.dispose();
    });

    testWidgets('finish 零部分结果 → 没听到内容（不卡拾音态）', (tester) async {
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.toggle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      unawaited(f.c.finish());
      await tester.pump(const Duration(milliseconds: 100));
      expect(f.errors.join(), contains('没听到内容'));
      expect(f.c.phase, VoiceDictationPhase.idle);
      f.c.dispose();
    });

    testWidgets('VOICE_HMS 开但插件缺席 → 错配自愈回退系统通道', (tester) async {
      debugVoiceHmsOverride = true;
      const hmsCh = MethodChannel('companion/hms_asr');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hmsCh, (call) async => false);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(hmsCh, null));
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.pushToTalk));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(calls.map((c) => c.method), contains('start'));
      f.c.dispose();
    });

    testWidgets('finish 8s 兜底：空部分结果也必然收尾', (tester) async {
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.toggle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      unawaited(f.c.finish());
      await tester.pump();
      await tester.pump(const Duration(seconds: 9));
      expect(f.errors.join(), contains('没听到内容'));
      f.c.dispose();
    });

    testWidgets('starting 期松开（finish）→ 丢弃不拾音', (tester) async {
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.pushToTalk));
      // 不 pump：仍在 starting/权限悬挂窗口即 finish。
      unawaited(f.c.finish());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(f.c.phase, VoiceDictationPhase.idle);
      expect(f.texts, isEmpty);
      f.c.dispose();
    });
  });

  // 早前批次：iOS 真人使用五断点回归（controller 单测形态）。
  group('早前批次 语音五断点', () {
    testWidgets('麦克风被拒：onError 标记需去设置', (tester) async {
      var opened = 0;
      _mockPermissionChannel(micStatus: 0, onOpenSettings: () => opened++);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.toggle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(f.errors.join(), contains('未授予麦克风权限'));
      expect(f.settings, [true]);
      // 「去设置」action 在页面侧；openAppSettings 可达性在此验证。
      expect(opened, 0); // 控制器不直接跳设置，页面 action 才跳
      f.c.dispose();
    });

    testWidgets('iOS 语音识别被拒：人话 + 需设置（不裸露 [9]）', (tester) async {
      VoiceDictationController.debugIosAsrErrorsOverride = true;
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.toggle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      _pushEvent({'type': 'error', 'code': 9, 'message': '未授权语音识别'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(f.errors.join(), contains('语音识别权限未开启'));
      expect(f.errors.join(), isNot(contains('[9]')));
      expect(f.settings, [true]);
      f.c.dispose();
    });

    testWidgets('iOS 网络类错误：人话网络提示（不引导去设置）', (tester) async {
      VoiceDictationController.debugIosAsrErrorsOverride = true;
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.toggle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      _pushEvent({'type': 'error', 'code': 1101, 'message': 'Try again'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(f.errors.join(), contains('网络连接不可用'));
      expect(f.settings, [false]);
      f.c.dispose();
    });

    testWidgets('iOS 没听清（1110 域码）：按没听到内容收尾', (tester) async {
      VoiceDictationController.debugIosAsrErrorsOverride = true;
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.toggle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      _pushEvent({'type': 'error', 'code': 1110, 'message': 'No speech'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(f.errors.join(), contains('没听到内容'));
      f.c.dispose();
    });

    testWidgets('iOS 取消类：有部分结果静默按部分结果收尾', (tester) async {
      VoiceDictationController.debugIosAsrErrorsOverride = true;
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.toggle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      _pushEvent({'type': 'partial', 'text': '已经说的内容'});
      await tester.pump();
      _pushEvent({'type': 'error', 'code': 216, 'message': 'canceled'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(f.texts, ['已经说的内容']);
      expect(f.errors, isEmpty);
      f.c.dispose();
    });

    testWidgets('iOS 取消类：零部分结果按没听到内容收尾', (tester) async {
      VoiceDictationController.debugIosAsrErrorsOverride = true;
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.toggle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      _pushEvent({'type': 'error', 'code': 216, 'message': 'canceled'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(f.errors.join(), contains('没听到内容'));
      f.c.dispose();
    });

    testWidgets('Android 错误码语义零变化', (tester) async {
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.toggle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      _pushEvent({'type': 'error', 'code': 4, 'message': 'server busy'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(f.errors.join(), contains('语音服务不可用：[4]'));
      f.c.dispose();
    });

    testWidgets('Android 没听清：有部分结果按部分结果收尾', (tester) async {
      _mockPermissionChannel(micStatus: 1);
      final f = _makeController();
      unawaited(f.c.start(VoiceDictationMode.toggle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      _pushEvent({'type': 'partial', 'text': '部分识别文字'});
      await tester.pump();
      _pushEvent({'type': 'error', 'code': 7, 'message': 'no match'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(f.texts, ['部分识别文字']);
      expect(f.errors, isEmpty);
      f.c.dispose();
    });

    test('iOS 错误码表：权限/网络/没听清/取消/未知兜底（纯函数）', () {
      expect(iosVoiceErrorMessage(9), contains('语音识别权限未开启'));
      expect(iosVoiceErrorMessage(1101), '网络连接不可用，请检查网络');
      expect(iosVoiceErrorMessage(203), '网络连接不可用，请检查网络');
      expect(iosVoiceErrorMessage(7), '没听到内容，再试一次');
      expect(iosVoiceErrorMessage(1110), '没听到内容，再试一次');
      expect(iosVoiceErrorMessage(216), isNull, reason: '取消类静默');
      expect(iosVoiceErrorMessage(301), isNull);
      expect(iosVoiceErrorMessage(-999), isNull);
      for (final code in [8, 10, 11, 1700, 201, 99999]) {
        final human = iosVoiceErrorMessage(code);
        expect(human, isNotNull);
        expect(human, isNot(contains('[$code]')));
        expect(RegExp(r'\d').hasMatch(human!), isFalse,
            reason: '未知/内部码不得把数字丢给用户（code=$code）');
      }
      expect(iosVoiceErrorNeedsSettings(9), isTrue);
      expect(iosVoiceErrorNeedsSettings(1101), isFalse);
      expect(iosVoiceErrorNeedsSettings(216), isFalse);
    });

    testWidgets('cancel 丢弃迟到整理结果（_disposed 守卫，原关面板用例平移）',
        (tester) async {
      final refine = Completer<String>();
      VoiceDictationController.debugRefineOverride = (_) => refine.future;
      addTearDown(() {
        if (!refine.isCompleted) refine.complete('迟到的整理稿');
      });
      _mockPermissionChannel(micStatus: 1);
      final app = AppState()..loaded = true;
      // setter 内存态同步生效；落盘在测试宿主无平台端，不 await。
      unawaited(app.uiPrefs.setVoiceApiKey('sk-test'));
      final f = _makeController(app: app);
      unawaited(f.c.start(VoiceDictationMode.toggle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      _pushEvent({'type': 'final', 'text': '帮我看下日志'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(f.c.phase, VoiceDictationPhase.refining);

      f.c.cancel(); // 原「关闭面板」语义
      await tester.pump();
      refine.complete('迟到的整理稿');
      await tester.pump();
      expect(f.texts, isEmpty, reason: 'cancel 后迟到整理不得落地');
      expect(tester.takeException(), isNull);
      f.c.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}