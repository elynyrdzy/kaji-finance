import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class DonutSlice {
  final double value;
  final Color color;
  const DonutSlice(this.value, this.color);
}

class DonutChartPainter extends CustomPainter {
  final List<DonutSlice> slices;
  final double strokeWidth;
  final int? highlightIndex;

  /// 0..1 — fraksi sweep yang tergambar (animasi sweep-in).
  final double progress;

  DonutChartPainter({
    required this.slices,
    this.strokeWidth = 20,
    this.highlightIndex,
    this.progress = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..color = AppColors.surfaceContainer
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawArc(rect, 0, 2 * math.pi, false, trackPaint);

    var startAngle = -math.pi / 2;
    final growth = progress.clamp(0.0, 1.0);
    for (var i = 0; i < slices.length; i++) {
      final slice = slices[i];
      final isHighlight = highlightIndex == i;
      final sweep = slice.value * 2 * math.pi * growth;
      final paint = Paint()
        ..color = isHighlight ? slice.color.withValues(alpha: 1.0) : slice.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = isHighlight ? strokeWidth + 4 : strokeWidth
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(rect, startAngle, sweep, false, paint);
      startAngle += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant DonutChartPainter oldDelegate) =>
      // listEquals (bukan identitas list) — lihat LineChartPainter.
      !listEquals(oldDelegate.slices, slices) ||
      oldDelegate.progress != progress ||
      oldDelegate.highlightIndex != highlightIndex;
}
