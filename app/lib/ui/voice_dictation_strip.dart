import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/theme.dart';
import '../state/voice_dictation_controller.dart';

/// 按住说话 inline 条带（2026-11-24 按住说话批，决策 26）：模态面板
/// 退役后的唯一语音 UI。QueueStrip 同款容器语言；相位驱动文案/计时；
/// pushToTalk=松开收尾/上滑取消提示；toggle=停止/取消按钮（≥48dp）。
/// 挂在页面 chrome Column 输入栏上方（条件兄弟，不换手手势子树）。
class VoiceDictationStrip extends StatelessWidget {
  final VoiceDictationController controller;

  const VoiceDictationStrip({super.key, required this.controller});

  String _fmt(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.active) return const SizedBox.shrink();
        final phase = controller.phase;
        final ptt = controller.mode == VoiceDictationMode.pushToTalk;
        final armed = controller.cancelArmed;
        final busy = phase == VoiceDictationPhase.finishing ||
            phase == VoiceDictationPhase.refining ||
            phase == VoiceDictationPhase.starting;
        return Container(
          key: const ValueKey('voice-strip'),
          decoration: BoxDecoration(
            color: context.colors.header.withValues(alpha: 0.95),
            border: Border(top: BorderSide(color: context.colors.border)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    armed
                        ? Icons.mic_off_outlined
                        : busy
                            ? Icons.hourglass_top
                            : Icons.graphic_eq,
                    size: 16,
                    color: armed
                        ? context.colors.destructive
                        : context.colors.brand,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _caption(context, phase, ptt, armed),
                  ),
                  if (busy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              // 开关式会话：停止/取消按钮（点按麦克风进入；无障碍出口）。
              if (!ptt &&
                  (phase == VoiceDictationPhase.listening ||
                      phase == VoiceDictationPhase.recording))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: FilledButton(
                            key: const ValueKey('voice-strip-stop'),
                            onPressed: controller.finish,
                            child: Text(
                              controller.cloudActive ? '停止并转写' : '说完了',
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 48,
                        child: TextButton(
                          key: const ValueKey('voice-strip-cancel'),
                          onPressed: controller.cancel,
                          child: const Text('取消'),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _caption(
    BuildContext context,
    VoiceDictationPhase phase,
    bool ptt,
    bool armed,
  ) {
    final subtle = TextStyle(
      fontSize: AppType.uiXs,
      color: context.colors.foregroundSubtle,
    );
    if (armed) {
      return Text(
        '松开取消',
        style: subtle.copyWith(color: context.colors.destructive),
      );
    }
    switch (phase) {
      case VoiceDictationPhase.starting:
        return Text('正在启动语音…', style: subtle);
      case VoiceDictationPhase.listening:
        final live = controller.partial;
        return Text(
          live.isNotEmpty
              ? live
              : tr(ptt ? '正在听你说，松开转写' : '正在听你说（说完点「说完了」）'),
          style: live.isNotEmpty
              ? TextStyle(
                  fontSize: AppType.uiBase,
                  color: context.colors.foreground,
                )
              : subtle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        );
      case VoiceDictationPhase.recording:
        return Row(
          children: [
            Text(_fmt(controller.recordSeconds), style: subtle),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                tr(ptt ? '松开转写 · 上滑取消' : '录音最长 2 分钟'),
                style: subtle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        );
      case VoiceDictationPhase.finishing:
        return Text(
          tr(controller.cloudActive ? '正在转写…' : '正在生成终稿…'),
          style: subtle,
        );
      case VoiceDictationPhase.refining:
        return Text('正在整理成规范指令…', style: subtle);
      case VoiceDictationPhase.idle:
        return const SizedBox.shrink();
    }
  }
}