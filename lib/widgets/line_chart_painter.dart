import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class LineChartPainter extends CustomPainter {
  final List<double> values;
  final Color lineColor;
  final int? highlightIndex;

  /// 0..1 — fraksi garis yang tergambar (animasi draw-in).
  final double progress;

  LineChartPainter({
    required this.values,
    this.lineColor = AppColors.tertiary,
    this.highlightIndex,
    this.progress = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    // Gambar bertahap dari kiri (draw-in) saat ganti periode.
    final clipW = (size.width * progress.clamp(0.0, 1.0)).clamp(
      0.0,
      size.width,
    );
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, clipW, size.height));

    final points = <Offset>[];
    final stepX = size.width / (values.length - 1);
    for (var i = 0; i < values.length; i++) {
      final x = stepX * i;
      final y = size.height - (values[i] * size.height);
      points.add(Offset(x, y));
    }

    final linePath = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      linePath.cubicTo(midX, p0.dy, midX, p1.dy, p1.dx, p1.dy);
    }

    final fillPath = Path.from(linePath)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          lineColor.withValues(alpha: 0.22),
          lineColor.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawPath(fillPath, fillPaint);

    final gridPaint = Paint()
      ..color = AppColors.surfaceContainerHigh
      ..strokeWidth = 1;
    for (final fraction in [0.25, 0.65]) {
      final y = size.height * fraction;
      _drawDashedLine(canvas, Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final linePaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(linePath, linePaint);

    if (highlightIndex != null &&
        highlightIndex! >= 0 &&
        highlightIndex! < points.length) {
      final p = points[highlightIndex!];
      canvas.drawCircle(
        p,
        10,
        Paint()..color = lineColor.withValues(alpha: 0.2),
      );
      canvas.drawCircle(p, 6, Paint()..color = lineColor);
      canvas.drawCircle(p, 3, Paint()..color = Colors.white);
    } else {
      canvas.drawCircle(
        points.last,
        8,
        Paint()..color = lineColor.withValues(alpha: 0.25),
      );
      canvas.drawCircle(points.last, 4, Paint()..color = lineColor);
    }
    canvas.restore();
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    const dashWidth = 3.0;
    const dashSpace = 3.0;
    final totalLength = (end - start).distance;
    var covered = 0.0;
    final direction = (end - start) / totalLength;
    while (covered < totalLength) {
      final segStart = start + direction * covered;
      final segEnd = start +
          direction *
              (covered + dashWidth > totalLength
                  ? totalLength
                  : covered + dashWidth);
      canvas.drawLine(segStart, segEnd, paint);
      covered += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant LineChartPainter oldDelegate) =>
      // listEquals (bukan identitas list): list baru dibangun tiap build,
      // sehingga `!=` selalu true dan efetivamente tak pernah bisa
      // mengembalikan false.
      !listEquals(oldDelegate.values, values) ||
      oldDelegate.lineColor != lineColor ||
      oldDelegate.progress != progress ||
      oldDelegate.highlightIndex != highlightIndex;
}
