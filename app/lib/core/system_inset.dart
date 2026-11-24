// 系统底部安全区直推通道（dual-pane-collapse-2 r3，vivo 任务栏遮挡终局）。
//
// 背景：vivo 展开态任务栏在原生 rootWindowInsets 里正常上报
//（navBars bottom=169px，zb-insets 探针实证），但 Flutter 的
// MediaQuery.viewPadding 拿到 0（透传链在 vivo 上断裂——探针/截图
// 双证：左栏间距 0 被遮、右栏正常=视口全屏而 Dart 安全区值缺失）。
// 不再赌框架透传：原生侧监听 decorView 的 insets 变化，把底部值
//（systemBars∪navigationBars∪displayCutout 取最大，逻辑 dp）实时
// 推给本模块；消费方取 max(MediaQuery.viewPadding.bottom, 本值)。
//
// 任务栏开/关、折叠/展开都会触发 insets 变化→实时跟随；键盘（ime
// 类型）不掺入（键盘弹出时多留的部分在键盘后面不可见，无可感知副作用）。
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 原生推送的底部安全区（逻辑 dp；0=未推送/无系统栏）。
final ValueNotifier<double> systemInsetBottomDp = ValueNotifier(0);

/// 原生推送的小窗顶栏（captionBar TOP source）高度（逻辑 dp；0=未推送/
/// 无顶栏）。消费点：[clampFreeformTopPadding] 的钳制目标值
/// （window-metrics-heal-1）。
final ValueNotifier<double> systemCaptionTopDp = ValueNotifier(0);

bool _initialized = false;

/// 注册原生反向推送（幂等；main 启动早期调用一次即可，未初始化的
/// 消费场景回落 MediaQuery——不比现状差）。
void initSystemInsetBridge() {
  if (_initialized) return;
  _initialized = true;
  const MethodChannel('companion/notify').setMethodCallHandler((call) async {
    if (call.method == 'systemInsetChanged') {
      final v = call.arguments;
      if (v is num) {
        systemInsetBottomDp.value = v.toDouble().clamp(0, 200);
      }
    }
    if (call.method == 'captionInsetChanged') {
      final v = call.arguments;
      if (v is num) {
        systemCaptionTopDp.value = v.toDouble().clamp(0, 200);
      }
    }
    return null;
  });
  refreshSystemInset();
  refreshCaptionInset();
}

/// 主动拉一次当前底部安全区——listener 首次推送常落在 Dart 就绪前
/// （变化驱动+任务栏常驻无变化=永久丢失，候选 06 真机实证）。init 调
/// 一次；失败静默（回落 MediaQuery 路径不劣于现状）。
Future<void> refreshSystemInset() {
  return const MethodChannel('companion/notify')
      .invokeMethod<num>('currentSystemInset')
      .then((v) {
    if (v != null) systemInsetBottomDp.value = v.toDouble().clamp(0, 200);
  }).catchError((_) {});
}

/// 主动拉一次当前小窗顶栏高度（与 [refreshSystemInset] 同款首推丢失
/// 兜底；window-metrics-heal-1）。
Future<void> refreshCaptionInset() {
  return const MethodChannel('companion/notify')
      .invokeMethod<num>('currentCaptionInset')
      .then((v) {
    if (v != null) systemCaptionTopDp.value = v.toDouble().clamp(0, 200);
  }).catchError((_) {});
}

/// 小窗异常 top padding 钳制（window-metrics-heal-1）。
///
/// 根因（Flutter 官方 issue flutter/flutter#161086，引擎源码核实）：
/// `FlutterViewDelegate.growViewportMetricsToCaptionBar` 取所有
/// captionBar boundingRect 的 `max(rect.bottom)` 作 viewPaddingTop；
/// HyperOS 小窗除顶栏外还有 **BOTTOM_CAPTION（底部拖拽把手）** source，
/// 其 rect.bottom≈窗口高 → top padding≈窗口高 → body 整体被推出可视区
/// （真机取证：小窗白屏、仅余不受 padding 影响的 Scaffold FAB）。
/// 引擎未修（issue 仍 open），issue 评论验证的 app 层解法=根 builder
/// 钳制异常 top padding；钳制目标值用原生直推的真实顶栏高度
/// （[systemCaptionTopDp]），避免内容被小窗标题栏遮挡。
///
/// 判据：top padding 超过窗口高一半即异常（状态栏/顶栏不可能占半窗）；
/// 正常路径原样返回（零变化）。padding 与 viewPadding 同钳（消费方
/// 两者都用）。
MediaQueryData clampFreeformTopPadding(MediaQueryData mq, double captionTopDp) {
  if (mq.size.height <= 0 || mq.padding.top <= mq.size.height / 2) return mq;
  final sane = captionTopDp.clamp(0.0, mq.size.height / 2);
  return mq.copyWith(
    padding: mq.padding.copyWith(top: sane),
    viewPadding: mq.viewPadding.copyWith(top: sane),
  );
}
