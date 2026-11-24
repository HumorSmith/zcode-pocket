import '../core/system_asr.dart';
import 'ui_prefs.dart';

/// 语音可用性/错误码纯函数与全局测试缝（原 voice_input_sheet 顶部
///  helpers，2026-11-24 按住说话批迁出——面板退役后消费点= composer
/// 入口判定与 controller 分派）。放 state 层：voiceEntryAvailableFor
/// 依赖 UiPrefs，core 不反向依赖 state。

/// HMS 识别是否启用（2026-10-28 脱敏翻转）：默认关闭——系统
/// SpeechRecognizer 是所有构建的唯一默认通道，不携带任何私有引擎
/// 倾向。私有包构建时经 --dart-define=VOICE_HMS=1 打开并注入
/// AGC_API_KEY（构建脚本成对注入），公开仓库的默认形态与
/// 文档只出现通用通道。测试缝：[debugVoiceHmsOverride]。
bool? debugVoiceHmsOverride;
const String _kVoiceHmsDefineValue = String.fromEnvironment('VOICE_HMS');

/// 1.0.1 验收根因：`bool.fromEnvironment('VOICE_HMS')` 只认字面
/// 'true'——构建传 `=1` 时探针串（String 语义）'zp-voice-hms:1' 断言
/// 通过而运行时 bool 恒 false（HMS 静默走系统通道=零回调；
/// 「正则改 (true|1)」恰好盖住此错配）。统一走 String 语义+宽容解析。
bool voiceHmsDefineEnabled(String value) {
  final v = value.trim().toLowerCase();
  return v == '1' || v == 'true';
}

bool get hmsVoiceConfigured =>
    debugVoiceHmsOverride ?? voiceHmsDefineEnabled(_kVoiceHmsDefineValue);

/// 语音识别可用性（两级）：系统识别服务可用（SystemAsr.available，
/// 启动预热——设备生态提供的通用识别能力）即可用；私有包打开
/// VOICE_HMS 时恒可用。皆无则隐藏入口。测试缝：
/// [debugVoiceRecognitionAvailable] 覆写。
bool? debugVoiceRecognitionAvailable;
bool get voiceRecognitionAvailable {
  final debug = debugVoiceRecognitionAvailable;
  if (debug != null) return debug;
  if (hmsVoiceConfigured) return true;
  if (SystemAsr.available) return true;
  // 缓存为空=启动探测尚未完成或开机瞬时失败（probe 失败不落缓存）。
  // 消费点按节流兜底重探，服务恢复后入口不会整会话隐藏（2026-11-08
  // 对抗审查；成功结果在下一次页面重建时可见）。
  SystemAsr.probeIfUnknown();
  return false;
}

/// 语音入口可用性（含云转写分支）：系统/HMS 之外，配置了 DeepSeek
/// 转写 key 时入口同样在场（批处理通道，录完再转写）。
bool voiceEntryAvailableFor(UiPrefs prefs) {
  final debug = debugVoiceRecognitionAvailable;
  if (debug != null) return debug;
  if (hmsVoiceConfigured) return true;
  if ((prefs.deepseekAsrKey ?? '').isNotEmpty) return true;
  if (SystemAsr.available) return true;
  SystemAsr.probeIfUnknown();
  return false;
}

/// iOS 系统语音错误码 → 用户可读文案（早前批次，纯函数）。
///
/// 返回 null=取消类静默（不弹失败态，有部分结果按部分结果收尾）。
/// 码表来源：
/// - AsrChannel.swift 自定义码 8（识别服务不可用）/ 9（未授权语音识别）/
///   10（音频会话被系统中断）/ 11（音频会话或引擎启动失败）；
/// - AsrChannel.errorCode(from:) 把 kAFAssistantErrorDomain 1110（未检测
///   到语音）折成 7，其余 NSError.code 原样透传；
/// - Apple Speech 框架没有公开稳定的数字码表，下列常见域码取自社区长期
///   实证：kAFAssistantErrorDomain 203/1101/1107=服务暂不可用或网络不稳，
///   216/301=识别被取消（例如被 Siri 等系统会话抢占），1700 与
///   kLSRErrorDomain 201=系统听写被禁用（与内部服务错误同收口）；
///   NSURLError -1001/-1005/-1009 为网络域失败。
/// 未知码一律收口到「语音服务未响应」人话，不再把数字丢给用户。
String? iosVoiceErrorMessage(int code) {
  switch (code) {
    case 9:
      return '语音识别权限未开启，请在系统设置中允许本应用访问语音识别';
    case 6 || 7 || 1110:
      return '没听到内容，再试一次';
    case 203 || 1101 || 1107 || -1001 || -1005 || -1009:
      return '网络连接不可用，请检查网络';
    case 216 || 301 || -999:
      return null; // 取消类：静默，不弹失败文案
    case 8 || 10 || 11 || 1700 || 201:
    default:
      return '语音服务未响应，请重试或改用键盘输入';
  }
}

/// iOS 权限类错误（语音识别被拒）需要「去设置」出口。
/// 麦克风被拒由 controller 的 Permission.microphone 分支单独标记。
bool iosVoiceErrorNeedsSettings(int code) => code == 9;