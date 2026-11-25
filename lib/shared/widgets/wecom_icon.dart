// MIT License
//
// Copyright (c) 2021-present TDesign
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// The path below is converted from Tencent TDesign's logo-wecom.svg:
// https://github.com/Tencent/tdesign-icons/blob/5bb64695572e558639c6006a14eaff67bdadc87b/svg/logo-wecom.svg

import 'package:material_ui/material_ui.dart';

/// The WeCom mark, rendered as a decorative icon using the current icon theme.
class WeComIcon extends StatelessWidget {
  const WeComIcon({super.key, this.size});

  final double? size;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final iconSize = size ?? iconTheme.size ?? 24;
    final color = iconTheme.color ?? Theme.of(context).colorScheme.onSurface;
    final opacity = iconTheme.opacity ?? 1;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: iconSize,
        child: CustomPaint(
          painter:
              _WeComIconPainter(color.withValues(alpha: color.a * opacity)),
        ),
      ),
    );
  }
}

class _WeComIconPainter extends CustomPainter {
  const _WeComIconPainter(this.color);

  final Color color;

  static final Path _path = Path()
    ..moveTo(17.3261, 8.15754)
    ..lineTo(17.3228, 8.15069)
    ..cubicTo(17.0394, 7.56412, 16.6404, 6.99422, 16.1445, 6.47713)
    ..cubicTo(14.8786, 5.17033, 13.0776, 4.28741, 11.0431, 4.05986)
    ..cubicTo(10.673, 4.01979, 10.3047, 4, 9.94957, 4)
    ..cubicTo(9.62263, 4, 9.27922, 4.0193, 8.91865, 4.05952)
    ..lineTo(8.91755, 4.05965)
    ..cubicTo(6.85659, 4.28839, 5.03568, 5.1673, 3.77824, 6.46538)
    ..cubicTo(3.27725, 6.98775, 2.87802, 7.54898, 2.58414, 8.14712)
    ..cubicTo(2.19144, 8.95433, 2, 9.79185, 2, 10.6574)
    ..cubicTo(2, 11.7632, 2.33191, 12.875, 2.98788, 13.8581)
    ..lineTo(2.99438, 13.8678)
    ..lineTo(2.99435, 13.8679)
    ..cubicTo(3.38549, 14.4616, 4.08579, 15.2583, 4.63143, 15.6982)
    ..lineTo(5.61433, 16.4906)
    ..lineTo(5.40578, 17.366)
    ..lineTo(5.93277, 17.0993)
    ..lineTo(6.64094, 16.7409)
    ..lineTo(7.40215, 16.9656)
    ..cubicTo(7.86891, 17.1034, 8.35651, 17.1927, 8.91862, 17.2554)
    ..lineTo(8.9244, 17.256)
    ..cubicTo(9.26741, 17.2953, 9.60902, 17.3149, 9.94957, 17.3149)
    ..cubicTo(10.3047, 17.3149, 10.6736, 17.295, 11.0448, 17.2549)
    ..cubicTo(11.5031, 17.2043, 11.955, 17.1167, 12.3913, 16.9973)
    ..cubicTo(12.4856, 17.6972, 12.8215, 18.3342, 13.3232, 18.8066)
    ..lineTo(13.3232, 18.8073)
    ..lineTo(13.3231, 18.8073)
    ..cubicTo(12.6647, 19.0154, 11.9712, 19.1649, 11.2619, 19.243)
    ..cubicTo(10.8205, 19.2908, 10.3791, 19.3149, 9.94957, 19.3149)
    ..cubicTo(9.53203, 19.3149, 9.11448, 19.2908, 8.69693, 19.243)
    ..cubicTo(8.05271, 19.1712, 7.44429, 19.0634, 6.83585, 18.8838)
    ..lineTo(3.99654, 20.3207)
    ..cubicTo(3.99654, 20.3207, 3.70563, 20.4523, 3.55512, 20.4523)
    ..cubicTo(3.13758, 20.4523, 2.85357, 20.1671, 2.85357, 19.748)
    ..cubicTo(2.85357, 19.4959, 2.92051, 19.1503, 2.98248, 18.9077)
    ..lineTo(3.37618, 17.2552)
    ..cubicTo(2.64845, 16.6686, 1.81334, 15.7106, 1.32422, 14.9682)
    ..cubicTo(0.453338, 13.663, 0, 12.1662, 0, 10.6574)
    ..cubicTo(0, 9.48394, 0.262458, 8.34638, 0.787376, 7.2687)
    ..cubicTo(1.18106, 6.46641, 1.70599, 5.73599, 2.33827, 5.0774)
    ..cubicTo(3.94881, 3.41297, 6.21551, 2.34726, 8.69693, 2.07185)
    ..cubicTo(9.1264, 2.02395, 9.54395, 2, 9.94957, 2)
    ..cubicTo(10.3791, 2, 10.8205, 2.02395, 11.2619, 2.07185)
    ..cubicTo(13.7314, 2.34726, 15.9742, 3.42495, 17.5847, 5.08937)
    ..cubicTo(18.217, 5.74795, 18.7419, 6.49037, 19.1237, 7.28066)
    ..cubicTo(19.5895, 8.22633, 19.8926, 9.2182, 19.8928, 10.2591)
    ..cubicTo(19.7117, 10.1958, 19.5219, 10.1488, 19.325, 10.1201)
    ..cubicTo(18.8263, 10.0474, 18.3382, 10.1001, 17.8928, 10.2544)
    ..cubicTo(17.8917, 9.60962, 17.7043, 8.92531, 17.3295, 8.16436)
    ..lineTo(17.3261, 8.15754)
    ..close()
    ..moveTo(21.4505, 15.1352)
    ..lineTo(21.4266, 15.1113)
    ..cubicTo(21.4207, 15.1053, 21.4116, 15.0992, 21.4026, 15.0932)
    ..cubicTo(21.3937, 15.0873, 21.3848, 15.0813, 21.3788, 15.0754)
    ..lineTo(21.2835, 14.9796)
    ..cubicTo(20.6632, 14.3569, 20.2693, 13.5906, 20.1144, 12.7883)
    ..cubicTo(20.1144, 12.7626, 20.1109, 12.7369, 20.1077, 12.7131)
    ..cubicTo(20.1049, 12.6925, 20.1023, 12.6732, 20.1023, 12.6566)
    ..lineTo(20.0666, 12.5129)
    ..cubicTo(20.0069, 12.2854, 19.8877, 12.0698, 19.7086, 11.9022)
    ..cubicTo(19.1719, 11.3633, 18.2891, 11.3633, 17.7521, 11.9022)
    ..cubicTo(17.2153, 12.441, 17.2153, 13.3271, 17.7521, 13.866)
    ..cubicTo(17.943, 14.0575, 18.1697, 14.1773, 18.4203, 14.2372)
    ..cubicTo(18.4442, 14.2491, 18.48, 14.2491, 18.5037, 14.2491)
    ..cubicTo(18.5157, 14.2491, 18.5306, 14.2521, 18.5455, 14.2551)
    ..cubicTo(18.5604, 14.2581, 18.5753, 14.2611, 18.5873, 14.2611)
    ..cubicTo(19.4104, 14.4168, 20.1859, 14.8119, 20.8181, 15.4465)
    ..cubicTo(20.8659, 15.4945, 20.9136, 15.5424, 20.9494, 15.5902)
    ..cubicTo(21.0806, 15.722, 21.2835, 15.722, 21.4147, 15.5902)
    ..cubicTo(21.546, 15.4585, 21.546, 15.267, 21.4505, 15.1352)
    ..close()
    ..moveTo(20.4001, 19.5059)
    ..lineTo(20.3762, 19.5298)
    ..cubicTo(20.257, 19.6257, 20.0661, 19.6257, 19.9228, 19.4938)
    ..cubicTo(19.7916, 19.3622, 19.7916, 19.1586, 19.9228, 19.027)
    ..cubicTo(19.9701, 18.9915, 20.0171, 18.9443, 20.0643, 18.8969)
    ..lineTo(20.0643, 18.8969)
    ..lineTo(20.0661, 18.8951)
    ..cubicTo(20.6983, 18.2605, 21.092, 17.4823, 21.2471, 16.656)
    ..cubicTo(21.2471, 16.6441, 21.2501, 16.6291, 21.2531, 16.6142)
    ..lineTo(21.2531, 16.6141)
    ..cubicTo(21.256, 16.5992, 21.259, 16.5842, 21.259, 16.5721)
    ..cubicTo(21.259, 16.5482, 21.259, 16.5123, 21.271, 16.4884)
    ..cubicTo(21.3307, 16.2369, 21.4499, 16.0093, 21.6408, 15.8178)
    ..cubicTo(22.1776, 15.2789, 23.0606, 15.2789, 23.5973, 15.8178)
    ..cubicTo(24.1341, 16.3567, 24.1341, 17.2427, 23.5973, 17.7816)
    ..cubicTo(23.4303, 17.9612, 23.2155, 18.081, 22.9889, 18.1408)
    ..lineTo(22.8458, 18.1768)
    ..cubicTo(22.8292, 18.1768, 22.8099, 18.1793, 22.7893, 18.1821)
    ..cubicTo(22.7656, 18.1853, 22.74, 18.1888, 22.7145, 18.1888)
    ..cubicTo(21.9151, 18.3444, 21.1517, 18.7395, 20.5313, 19.3622)
    ..lineTo(20.4359, 19.4581)
    ..cubicTo(20.4299, 19.464, 20.4239, 19.4731, 20.4179, 19.4821)
    ..lineTo(20.4179, 19.4821)
    ..cubicTo(20.4119, 19.491, 20.406, 19.4999, 20.4001, 19.5059)
    ..close()
    ..moveTo(16.0095, 18.452)
    ..lineTo(16.0334, 18.4759)
    ..cubicTo(16.0394, 18.4819, 16.0484, 18.488, 16.0574, 18.494)
    ..lineTo(16.0575, 18.4941)
    ..cubicTo(16.0663, 18.5, 16.0752, 18.5059, 16.081, 18.5118)
    ..lineTo(16.1765, 18.6075)
    ..cubicTo(16.7969, 19.2303, 17.1905, 19.9966, 17.3457, 20.7989)
    ..cubicTo(17.3457, 20.8246, 17.3491, 20.8503, 17.3522, 20.8741)
    ..lineTo(17.3523, 20.8742)
    ..cubicTo(17.355, 20.8948, 17.3575, 20.9141, 17.3575, 20.9307)
    ..lineTo(17.3935, 21.0743)
    ..cubicTo(17.453, 21.3018, 17.5723, 21.5174, 17.7514, 21.685)
    ..cubicTo(18.2882, 22.2239, 19.171, 22.2239, 19.7078, 21.685)
    ..cubicTo(20.2447, 21.1461, 20.2447, 20.2601, 19.7078, 19.7212)
    ..cubicTo(19.517, 19.5296, 19.2903, 19.4099, 19.0397, 19.35)
    ..cubicTo(19.0158, 19.3381, 18.9801, 19.3381, 18.9562, 19.3381)
    ..cubicTo(18.9443, 19.3381, 18.9295, 19.3351, 18.9146, 19.3321)
    ..cubicTo(18.8997, 19.3291, 18.8847, 19.3261, 18.8727, 19.3261)
    ..cubicTo(18.0496, 19.1705, 17.2741, 18.7753, 16.6419, 18.1407)
    ..cubicTo(16.5941, 18.0927, 16.5464, 18.0448, 16.5107, 17.997)
    ..cubicTo(16.3794, 17.8653, 16.1765, 17.8653, 16.0453, 17.997)
    ..cubicTo(15.9022, 18.1286, 15.9022, 18.3322, 16.0095, 18.452)
    ..close()
    ..moveTo(17.0476, 14.0936)
    ..lineTo(17.0715, 14.0696)
    ..cubicTo(17.2027, 13.9619, 17.3936, 13.9619, 17.5248, 14.1055)
    ..cubicTo(17.6561, 14.2373, 17.6561, 14.4408, 17.5248, 14.5725)
    ..cubicTo(17.4777, 14.608, 17.4307, 14.6551, 17.3835, 14.7023)
    ..lineTo(17.3816, 14.7043)
    ..cubicTo(16.7493, 15.3389, 16.3557, 16.1172, 16.2005, 16.9435)
    ..cubicTo(16.2005, 16.9554, 16.1976, 16.9704, 16.1946, 16.9854)
    ..cubicTo(16.1916, 17.0003, 16.1887, 17.0153, 16.1887, 17.0272)
    ..cubicTo(16.1887, 17.0513, 16.1887, 17.0872, 16.1768, 17.1111)
    ..cubicTo(16.1171, 17.3626, 15.9978, 17.59, 15.8069, 17.7817)
    ..cubicTo(15.2701, 18.3206, 14.3872, 18.3206, 13.8504, 17.7817)
    ..cubicTo(13.3135, 17.2428, 13.3135, 16.3567, 13.8504, 15.8179)
    ..cubicTo(14.0174, 15.6383, 14.2321, 15.5185, 14.4588, 15.4587)
    ..lineTo(14.602, 15.4227)
    ..cubicTo(14.6186, 15.4227, 14.6378, 15.4201, 14.6583, 15.4174)
    ..lineTo(14.6583, 15.4174)
    ..lineTo(14.6584, 15.4174)
    ..cubicTo(14.6821, 15.4142, 14.7076, 15.4107, 14.7332, 15.4107)
    ..cubicTo(15.5325, 15.2551, 16.296, 14.86, 16.9163, 14.2373)
    ..lineTo(17.0118, 14.1415)
    ..cubicTo(17.0179, 14.1354, 17.0239, 14.1263, 17.0299, 14.1173)
    ..cubicTo(17.0358, 14.1084, 17.0417, 14.0995, 17.0476, 14.0936)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    canvas.drawPath(_path, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WeComIconPainter oldDelegate) =>
      color != oldDelegate.color;
}
