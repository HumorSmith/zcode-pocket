import 'dart:async';
import 'dart:io' show Process;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/audio_capture.dart';
import '../core/deepseek_asr.dart';
import '../core/hms_asr.dart';
import '../core/l10n.dart' show L10n, tr;
import '../core/system_asr.dart';
import '../core/voice_refine.dart';
import 'ui_prefs.dart';
import 'voice_availability.dart';

/// 按住说话会话模式：pushToTalk=按住录音/松开收尾/上滑取消；
/// toggle=点按开始，inline 条带按钮停止/取消（无障碍与既有
/// 「点按麦克风可达」契约）。
enum VoiceDictationMode { pushToTalk, toggle }

/// 会话相位（idle=无会话；strip 隐藏）。finishing 合并原 uploading/
/// recognizing（云上传转写/系统等终稿），refining=口语整理。
enum VoiceDictationPhase { idle, starting, listening, recording, finishing, refining }

enum _Channel { none, hms, system, cloud }

/// 语音听写控制器（2026-11-24 按住说话批：原 voice_input_sheet 状态机
/// 平移，UI 无关化）。页面持有实例，inline 条带消费相位，手势驱动
/// start/finish/cancel。终稿经 [onText] 交页面落输入框（决策 9：不自动
/// 发送）；失败经 [onError] 交页面 snackbar 人话（决策 24）。
///
/// 分派与护栏与原面板同语义：HMS（私有构建）→系统（实时 partial）→
/// 云批处理（DeepSeek ASR，录完再转写）；probe 假阳 ROM 由系统通道
/// onError 兜底切云；零回调看门狗 10s/45s/15s 档；云 120s 自动停；
/// 等终稿 8s 兜底；整理 10s 总期限、失败退原文。所有终态释放麦克风。
class VoiceDictationController extends ChangeNotifier {
  VoiceDictationController({
    required UiPrefs prefs,
    required this.onText,
    required this.onError,
  }) : _prefs = prefs;

  final UiPrefs _prefs;

  /// 转写（+可选整理）完成：text=进输入框的稿（整理成功=整理稿），
  /// original=听写原文，refineOk=整理是否生效（页面据此 snackbar「用原文」）。
  final void Function(String text, String original, bool refineOk) onText;

  /// 失败人话；needsSettings=权限类（页面给「去设置」action）。
  final void Function(String message, bool needsSettings) onError;

  /// 测试缝：强制云转写分支 key（null=跟随设置解析）。
  @visibleForTesting
  static String? debugCloudKeyOverride;

  /// 测试缝：替换转写请求（null=生产 [transcribeDictation]）。
  @visibleForTesting
  static Future<String> Function(Uint8List wav)? debugAsrOverride;

  /// 测试缝：替换口语整理请求（null=生产 [refineDictation]）。
  @visibleForTesting
  static Future<String> Function(String raw)? debugRefineOverride;

  /// 测试缝：强制按 iOS 错误码表解释系统识别错误（null=跟随运行平台）。
  @visibleForTesting
  static bool? debugIosAsrErrorsOverride;

  VoiceDictationPhase _phase = VoiceDictationPhase.idle;
  VoiceDictationMode _mode = VoiceDictationMode.pushToTalk;
  _Channel _channel = _Channel.none;
  String _partial = '';
  int _recordSeconds = 0;
  bool _cancelArmed = false;
  bool _disposed = false;

  HmsAsrSession? _hmsSession;
  SystemAsrSession? _systemSession;
  VoiceRecorder? _cloudRecorder;
  Timer? _recordTicker;
  Timer? _recordCapTimer;
  Timer? _engineWatchdog;
  Timer? _finalFallbackTimer;
  String _cloudKey = '';
  String? _cloudFallbackKey;
  Completer<String>? _finalCompleter;
  bool _finalListened = false;

  VoiceDictationPhase get phase => _phase;
  VoiceDictationMode get mode => _mode;
  String get partial => _partial;
  int get recordSeconds => _recordSeconds;
  bool get cancelArmed => _cancelArmed;
  bool get active => _phase != VoiceDictationPhase.idle;

  /// finishing 相位文案分流：云=上传转写；系统/HMS=等终稿。
  bool get cloudActive => _channel == _Channel.cloud;

  void _log(String line) => debugPrint('[voice] $line');

  void _set(void Function() mutate) {
    if (_disposed) return;
    mutate();
    notifyListeners();
  }

  /// 识别语言跟随 app 界面语言（英文界面不塞中文引擎）。
  String get _asrLanguage =>
      L10n.resolvedLocale == 'en-US' ? 'en-US' : 'zh-CN';

  bool get _iosAsrErrors =>
      debugIosAsrErrorsOverride ?? defaultTargetPlatform == TargetPlatform.iOS;

  /// 开始会话（idle 才受理；sending 闸在页面侧）。
  Future<void> start(VoiceDictationMode mode) async {
    if (_disposed || active) return;
    _mode = mode;
    _partial = '';
    _recordSeconds = 0;
    _cancelArmed = false;
    _channel = _Channel.none;
    _finalCompleter = Completer<String>();
    _finalListened = false;
    _set(() => _phase = VoiceDictationPhase.starting);
    _log('hmsVoiceConfigured=$hmsVoiceConfigured（mode=$mode）');
    // 通道分派：HMS（私有构建）→系统→云；错配自愈同原面板。
    final hmsReady = hmsVoiceConfigured && await HmsAsr.probe();
    if (_disposed || !active) return; // await 恢复点守卫（麦克风隐私）
    if (hmsReady) {
      await _startHms();
      return;
    }
    if (hmsVoiceConfigured) {
      _log('HMS 插件缺席（VOICE_HMS 开关与原生源集错配）→ 回退系统通道');
    }
    _cloudFallbackKey = debugCloudKeyOverride ?? _prefs.deepseekAsrKey;
    final sysReady = SystemAsr.available || await SystemAsr.probe();
    if (_disposed || !active) return;
    if (sysReady) {
      await _startSystem();
      return;
    }
    final key = _cloudFallbackKey;
    if (key != null && key.isNotEmpty) {
      await _startCloud(key);
      return;
    }
    _fail(tr('当前设备无可用语音服务'), false);
  }

  /// 上滑取消武装（pushToTalk 手势移动驱动）；松开时 finish 见 armed 即 cancel。
  void armCancel(bool armed) {
    if (_disposed || !active || _mode != VoiceDictationMode.pushToTalk) return;
    if (_cancelArmed == armed) return;
    _set(() => _cancelArmed = armed);
  }

  /// 松开/停止按钮：armed→丢弃；starting 期松开→丢弃（不得手指离键
  /// 后继续拾音）；云→停录音上传转写；系统/HMS→停拾音等终稿。
  Future<void> finish() async {
    if (_disposed || !active) return;
    if (_cancelArmed) {
      cancel();
      return;
    }
    if (_phase == VoiceDictationPhase.starting) {
      cancel();
      return;
    }
    if (_phase != VoiceDictationPhase.listening &&
        _phase != VoiceDictationPhase.recording) {
      return;
    }
    if (_channel == _Channel.cloud) {
      await _finishCloud();
      return;
    }
    _engineAlive();
    _set(() => _phase = VoiceDictationPhase.finishing);
    _systemSession?.stop();
    unawaited(_hmsSession?.stop() ?? Future<void>.value());
    _listenFinal();
    // 松开即收尾：系统/HMS 有 partial 立即用当前文字（push-to-talk 不
    // 等终稿）；零 partial 以空稿收尾→「没听到内容」。8s 兜底仅作安全网
    // （completer 已完成时为 no-op）。
    final c = _finalCompleter;
    if (c != null && !c.isCompleted) c.complete(_partial);
    _finalFallbackTimer?.cancel();
    _finalFallbackTimer = Timer(const Duration(seconds: 8), () {
      final cc = _finalCompleter;
      if (_disposed || cc == null || cc.isCompleted) return;
      cc.complete(_partial);
    });
  }

  /// 丢弃会话：立即释放麦克风（隐私），strip 隐藏。
  void cancel() {
    if (_disposed) return;
    _releaseEngines();
    _set(() {
      _phase = VoiceDictationPhase.idle;
      _partial = '';
      _cancelArmed = false;
      _channel = _Channel.none;
    });
  }

  void _releaseEngines() {
    _engineWatchdog?.cancel();
    _recordTicker?.cancel();
    _recordCapTimer?.cancel();
    _finalFallbackTimer?.cancel();
    unawaited(_hmsSession?.cancel() ?? Future<void>.value());
    _hmsSession = null;
    _systemSession?.cancel();
    _systemSession = null;
    unawaited(_cloudRecorder?.cancel() ?? Future<void>.value());
    _cloudRecorder = null;
  }

  void _fail(String message, bool needsSettings) {
    if (_disposed) return;
    _releaseEngines();
    _set(() {
      _phase = VoiceDictationPhase.idle;
      _partial = '';
      _cancelArmed = false;
      _channel = _Channel.none;
    });
    onError(message, needsSettings);
  }

  /// x86/x86_64 ABI 检测（HMS 原生库无 x86 版护栏；失败按 arm）。
  Future<bool> _nonArmAbi() async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final r = Process.runSync('getprop', ['ro.product.cpu.abi']);
      final abi = '${r.stdout}'.trim();
      final nonArm = abi.startsWith('x86');
      if (nonArm) _log('abi=$abi → 不可用分支（HMS 原生库无 x86 版）');
      return nonArm;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startCloud(String key) async {
    final mic = await Permission.microphone.request();
    if (_disposed || !active) return;
    if (mic != PermissionStatus.granted) {
      _fail(tr('未授予麦克风权限（设置→应用→权限）'), true);
      return;
    }
    _cloudKey = key;
    final rec = createVoiceRecorder();
    try {
      await rec.start();
    } catch (e) {
      _log('cloud recorder start failed: $e');
      if (_disposed || !active) return;
      _fail(tr('语音服务未响应，请重试或改用键盘输入'), false);
      return;
    }
    if (_disposed || !active) {
      unawaited(rec.cancel());
      return;
    }
    _cloudRecorder = rec;
    _channel = _Channel.cloud;
    _recordSeconds = 0;
    _recordTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_disposed && active) _set(() => _recordSeconds++);
    });
    _recordCapTimer = Timer(kAsrMaxDuration, finish);
    _set(() => _phase = VoiceDictationPhase.recording);
  }

  Future<void> _finishCloud() async {
    if (_phase != VoiceDictationPhase.recording || _disposed) return;
    _recordTicker?.cancel();
    _recordCapTimer?.cancel();
    final rec = _cloudRecorder;
    _cloudRecorder = null;
    if (rec == null) return;
    _set(() => _phase = VoiceDictationPhase.finishing);
    Uint8List wav;
    try {
      wav = await rec.stop();
    } catch (e) {
      _log('cloud recorder stop failed: $e');
      wav = Uint8List(0);
    }
    if (_disposed || !active) return;
    if (wav.isEmpty) {
      _fail('没听到内容，再试一次', false);
      return;
    }
    try {
      final override = debugAsrOverride;
      final text = override != null
          ? await override(wav)
          : await transcribeDictation(apiKey: _cloudKey, wav: wav);
      if (_disposed || !active) return;
      await _complete(text);
    } on DeepseekAsrException catch (e) {
      _log('cloud asr error code=${e.code}');
      if (_disposed || !active) return;
      _fail(e.message, false);
    } catch (e) {
      _log('cloud asr failed: $e');
      if (_disposed || !active) return;
      _fail(tr('语音服务未响应，请重试或改用键盘输入'), false);
    }
  }

  Future<void> _startHms() async {
    if (await _nonArmAbi()) {
      if (_disposed || !active) return;
      _fail(tr('此设备 CPU 不支持当前语音服务'), false);
      return;
    }
    final mic = await Permission.microphone.request();
    if (_disposed || !active) return;
    if (mic != PermissionStatus.granted) {
      _fail(tr('未授予麦克风权限（设置→应用→权限）'), true);
      return;
    }
    try {
      const agcApiKey = String.fromEnvironment('AGC_API_KEY');
      _channel = _Channel.hms;
      _set(() => _phase = VoiceDictationPhase.listening);
      _armEngineWatchdog(const Duration(seconds: 15));
      _listenFinal();
      _hmsSession = HmsAsr.start(
        apiKey: agcApiKey.isEmpty ? null : agcApiKey,
        language: _asrLanguage,
        onPartial: _onPartial,
        onFinal: _onFinal,
        onError: (code, message) {
          _engineAlive();
          _log('error code=$code msg=$message');
          final c = _finalCompleter;
          if (c == null || c.isCompleted) return;
          c.completeError('[$code] $message');
        },
      );
    } catch (e) {
      _fail('${tr('语音服务不可用：')}$e', false);
    }
  }

  Future<void> _startSystem() async {
    final mic = await Permission.microphone.request();
    if (_disposed || !active) return;
    if (mic != PermissionStatus.granted) {
      _fail(tr('未授予麦克风权限（设置→应用→权限）'), true);
      return;
    }
    _set(() => _phase = VoiceDictationPhase.starting);
    // iOS 首启宽窗：系统通道两段式权限请求，首启弹框停留超 10s 不判死。
    _armEngineWatchdog(
      defaultTargetPlatform == TargetPlatform.iOS
          ? const Duration(seconds: 45)
          : const Duration(seconds: 10),
    );
    _listenFinal();
    _channel = _Channel.system;
    _systemSession = SystemAsr.start(
      language: _asrLanguage,
      onPartial: _onPartial,
      onFinal: _onFinal,
      onError: _onSystemError,
    );
    _set(() => _phase = VoiceDictationPhase.listening);
  }

  void _onPartial(String text) {
    if (_disposed || !active) return;
    _engineAlive();
    // 迟到 partial 不复活 finishing/refining（看门狗判死后引擎复活漂移）。
    if (_phase != VoiceDictationPhase.listening &&
        _phase != VoiceDictationPhase.starting) {
      return;
    }
    _set(() {
      _partial = text;
      _phase = VoiceDictationPhase.listening;
    });
  }

  void _onFinal(String text) {
    _engineAlive();
    _log('final: $text');
    final c = _finalCompleter;
    if (c != null && !c.isCompleted) c.complete(text);
  }

  void _onSystemError(int code, String message) {
    _engineAlive();
    _log('sys error code=$code msg=$message');
    final c = _finalCompleter;
    if (c == null || c.isCompleted) return;
    // 可用性类失败（无服务/插件缺席）且零部分结果：probe 假阳 ROM
    // 兜底——有云 key 切云转写（小米 17 真机实锤）。
    if ((code == 5 || code == -1) &&
        _partial.trim().isEmpty &&
        (_cloudFallbackKey ?? '').isNotEmpty) {
      _log('sys unavailable code=$code → 云转写兜底');
      _engineWatchdog?.cancel();
      unawaited(_systemSession?.cancel() ?? Future<void>.value());
      _systemSession = null;
      if (_disposed || !active) return;
      unawaited(_startCloud(_cloudFallbackKey!));
      return;
    }
    // 有部分结果时 6/7 按部分结果收尾；其余按平台映射。
    if ((code == 6 || code == 7) && _partial.trim().isNotEmpty) {
      c.complete(_partial);
      return;
    }
    if (_iosAsrErrors) {
      final human = iosVoiceErrorMessage(code);
      if (human == null) {
        c.complete(_partial.trim().isNotEmpty ? _partial : '');
        return;
      }
      if (iosVoiceErrorNeedsSettings(code)) {
        _fail(tr(human), true);
        return;
      }
      c.completeError(tr(human));
      return;
    }
    c.completeError(
      code == 6 || code == 7 ? '没听到内容，再试一次' : '语音服务不可用：[$code]',
    );
  }

  void _engineAlive() => _engineWatchdog?.cancel();

  void _armEngineWatchdog([Duration duration = const Duration(seconds: 10)]) {
    _engineWatchdog?.cancel();
    _engineWatchdog = Timer(duration, () {
      final c = _finalCompleter;
      if (_disposed || (c?.isCompleted ?? true)) return;
      _log('engine watchdog: ${duration.inSeconds}s 零回调（识别服务无响应）');
      _fail(tr('语音服务未响应，请重试或改用键盘输入'), false);
    });
  }

  /// final/error 一到达即驱动收尾（幂等防双挂接）。
  void _listenFinal() {
    if (_finalListened) return;
    final c = _finalCompleter;
    if (c == null) return;
    _finalListened = true;
    c.future.then(
      _complete,
      onError: (Object e) {
        if (_disposed || !active) return;
        _fail('${tr('识别失败：')}$e', false);
      },
    );
  }

  /// 终稿 →（可选整理）→ onText 交页面落输入框。
  Future<void> _complete(String original) async {
    if (_disposed || !active) return;
    final text = original.trim();
    if (text.isEmpty) {
      _fail('没听到内容，再试一次', false);
      return;
    }
    var result = text;
    var ok = false;
    final configured =
        _prefs.voiceRefineEnabled && (_prefs.voiceApiKey ?? '').trim().isNotEmpty;
    if (configured) {
      _set(() => _phase = VoiceDictationPhase.refining);
      final override = debugRefineOverride;
      final refined = override != null
          ? await override(text)
          : await refineDictation(
              apiKey: _prefs.voiceApiKey,
              raw: text,
              providerId: _prefs.voiceApiProvider,
            );
      if (_disposed || !active) return; // 迟到整理结果丢弃（cancel/dispose 守卫）
      if (refined.trim().isNotEmpty && refined.trim() != text) {
        result = refined.trim();
        ok = true;
      }
    }
    _releaseEngines();
    _set(() {
      _phase = VoiceDictationPhase.idle;
      _partial = '';
      _cancelArmed = false;
      _channel = _Channel.none;
    });
    onText(result, text, ok);
  }

  @override
  void dispose() {
    _disposed = true;
    _releaseEngines();
    super.dispose();
  }
}